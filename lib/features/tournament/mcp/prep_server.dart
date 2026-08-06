/// A loopback HTTP server that exposes the prep tools to an MCP shim.
///
/// ## Why the app hosts this instead of shipping a CLI
///
/// The obvious design — a standalone `dart compile exe` binary reusing
/// `lib/services/` — is not available here: 59 files under `services/`,
/// `core/`, `models/` and `utils/` import `package:flutter/foundation.dart`,
/// and the engine stack (Stockfish, ONNX Runtime, sqflite FFI) is
/// plugin-based, so it needs a Flutter host to register.
///
/// Hosting the bridge inside the running app is better anyway. Engine
/// warm-up, the Maia session and the SQLite eval cache are all expensive and
/// long-lived; a per-invocation CLI would pay that cost once per opponent,
/// and a forty-player entry list would pay it forty times. Here the agent
/// talks to an already-warm process.
///
/// ## Security posture
///
/// Bound to loopback only, never a routable interface, and every request
/// needs a bearer token generated at enable time. The token and port are
/// written to a file in the app support directory so the shim can find them
/// without the user copying anything by hand; that file is the only thing
/// that grants access, so it is written with owner-only permissions where the
/// platform supports it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../services/storage/app_paths.dart';
import '../../../utils/atomic_file.dart';
import '../services/tournament_session.dart';
import 'prep_tools.dart';

/// Name of the endpoint descriptor the stdio shim reads.
const String kMcpEndpointFileName = 'mcp_endpoint.json';

class PrepServerStatus {
  final bool running;
  final int? port;
  final String? endpointFile;

  const PrepServerStatus({required this.running, this.port, this.endpointFile});
}

class PrepServer {
  final TournamentSession session;
  late final PrepToolRegistry _registry = PrepToolRegistry(session);

  HttpServer? _server;
  String? _token;

  PrepServer(this.session);

  bool get isRunning => _server != null;
  int? get port => _server?.port;
  String? get token => _token;

  PrepServerStatus get status =>
      PrepServerStatus(running: isRunning, port: port);

  /// Directory the endpoint descriptor is written to. Null means the app
  /// support directory, which is where the shim looks; tests override it
  /// because resolving that path needs a platform plugin.
  Directory? _endpointDirectory;

  /// Start on [preferredPort], or an ephemeral port when it is 0/taken.
  ///
  /// Returns the descriptor file path the shim should be pointed at.
  Future<String> start({
    int preferredPort = 0,
    Directory? endpointDirectory,
  }) async {
    _endpointDirectory = endpointDirectory;
    if (_server != null) return _endpointPath();

    _token = _generateToken();

    HttpServer server;
    try {
      server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        preferredPort,
      );
    } on SocketException {
      // The preferred port was taken; fall back to whatever is free rather
      // than failing to start.
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    }

    _server = server;
    server.listen(
      _handle,
      onError: (Object e) {
        if (kDebugMode) debugPrint('[PrepServer] $e');
      },
    );

    final path = await _writeEndpointFile();
    if (kDebugMode) {
      debugPrint('[PrepServer] listening on 127.0.0.1:${server.port}');
    }
    return path;
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _token = null;
    try {
      final file = File(await _endpointPath());
      if (await file.exists()) await file.delete();
    } catch (_) {
      // A leftover descriptor is harmless — the token in it is already dead.
    }
  }

  // ── Request handling ───────────────────────────────────────────────────

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    // The charset is not decoration. `HttpResponse.write` encodes with the
    // content type's charset and defaults to latin1, which throws on any
    // non-ASCII byte — and the tool descriptions are full of `→`, `—` and `×`.
    // Bodies are emitted as explicit UTF-8 bytes below so the encoding can
    // never be inferred wrongly.
    response.headers.contentType = ContentType(
      'application',
      'json',
      charset: 'utf-8',
    );

    Object? body;
    try {
      if (!_authorized(request)) {
        response.statusCode = HttpStatus.unauthorized;
        _writeJson(response, {'error': 'Unauthorized'});
        await response.close();
        return;
      }

      final path = request.uri.path;

      if (path == '/health' && request.method == 'GET') {
        body = {
          'ok': true,
          'app': 'Chess Auto Prep',
          'tools': _registry.tools.length,
          'roster_entries': session.roster.entries.length,
          'preparing': session.isPreparing,
        };
      } else if (path == '/tools' && request.method == 'GET') {
        body = {'tools': _registry.definitions};
      } else if (path == '/call' && request.method == 'POST') {
        final raw = await utf8.decoder.bind(request).join();
        final decoded = raw.trim().isEmpty
            ? const <String, dynamic>{}
            : json.decode(raw) as Map<String, dynamic>;

        final name = decoded['name'] as String?;
        if (name == null || name.isEmpty) {
          response.statusCode = HttpStatus.badRequest;
          body = {'ok': false, 'error': 'Missing "name".'};
        } else {
          final args =
              (decoded['arguments'] as Map?)?.cast<String, dynamic>() ??
              const <String, dynamic>{};
          body = await _registry.callEncoded(name, args);
        }
      } else {
        response.statusCode = HttpStatus.notFound;
        body = {'error': 'No such endpoint: $path'};
      }
    } catch (e) {
      response.statusCode = HttpStatus.internalServerError;
      body = {'ok': false, 'error': '$e'};
    }

    try {
      _writeJson(response, body);
    } catch (e) {
      // Encoding the body itself failed. Answer with something that certainly
      // encodes rather than leaving the client hanging on an open socket.
      response.statusCode = HttpStatus.internalServerError;
      _writeJson(response, {'ok': false, 'error': 'Response encoding failed.'});
    }

    await response.close();
  }

  /// Emit [value] as UTF-8 bytes, bypassing the outbound message's charset.
  static void _writeJson(HttpResponse response, Object? value) {
    response.add(utf8.encode(json.encode(value)));
  }

  bool _authorized(HttpRequest request) {
    final expected = _token;
    if (expected == null) return false;
    final header = request.headers.value('authorization') ?? '';
    if (!header.startsWith('Bearer ')) return false;
    return _constantTimeEquals(header.substring(7), expected);
  }

  /// Compare without leaking length-prefix timing. Overkill for a loopback
  /// socket, but the cost is nil and the habit is right.
  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  static String _generateToken() {
    final rng = Random.secure();
    final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  // ── Endpoint descriptor ────────────────────────────────────────────────

  Future<String> _endpointPath() async {
    final dir = _endpointDirectory ?? await AppPaths.supportDirectory();
    return p.join(dir.path, kMcpEndpointFileName);
  }

  Future<String> _writeEndpointFile() async {
    final path = await _endpointPath();
    final file = File(path);

    await writeTextFileAtomically(
      file,
      const JsonEncoder.withIndent('  ').convert({
        'url': 'http://127.0.0.1:${_server!.port}',
        'token': _token,
        'app': 'Chess Auto Prep',
      }),
    );

    // Best effort: the token is a credential, so keep it owner-readable.
    if (!Platform.isWindows) {
      try {
        await Process.run('chmod', ['600', path]);
      } catch (_) {
        // Non-fatal; the file still sits inside the user's own app support
        // directory.
      }
    }

    return path;
  }

  /// Where the shim expects to find the descriptor, for display in Settings.
  static Future<String> endpointFilePath() async {
    final dir = await AppPaths.supportDirectory();
    return p.join(dir.path, kMcpEndpointFileName);
  }
}

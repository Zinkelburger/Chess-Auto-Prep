import 'dart:async';
import 'dart:convert';

import 'package:dartchess/dartchess.dart' show Side;
import 'package:http/http.dart' as http;

import '../diagnostics/log.dart';
import 'lichess_http.dart';

/// Writing a study to the user's Lichess account.
///
/// Three calls of Lichess's study API, each needing the `study:write`
/// permission: make a study, add a chapter to one, and put a chapter's moves
/// and tags in place of the ones Lichess has. The token is read at each call,
/// so logging in again between two attempts is enough, and it never reaches
/// the log.

/// What one write came to.
sealed class LichessWrite {
  const LichessWrite();
}

/// Done; [id] names what was made, when the call made something.
final class LichessWritten extends LichessWrite {
  const LichessWritten([this.id]);

  final String? id;
}

/// Why a write did not happen, as a sentence the user is shown.
enum LichessWriteProblem {
  signedOut('Log in to Lichess to send a study.'),
  permission(
    'Lichess needs your permission to write studies. Log in again to give '
    'it.',
  ),
  notFound('Lichess has no such study or chapter that your account can edit.'),
  limited('Lichess is limiting requests. Wait a minute, then send again.'),
  rejected('Lichess could not read a chapter.'),
  unreachable(
    'Lichess did not respond. Check the connection, then send again.',
  ),
  http('Lichess could not take the study.');

  const LichessWriteProblem(this.sentence);

  final String sentence;

  /// Whether logging in (again) is the way out.
  bool get needsLogin => this == signedOut || this == permission;
}

final class LichessNotWritten extends LichessWrite {
  const LichessNotWritten(this.problem, {this.detail});

  final LichessWriteProblem problem;

  /// What Lichess said, when it said why.
  final String? detail;

  String get sentence => detail == null || detail!.isEmpty
      ? problem.sentence
      : '${problem.sentence} Lichess said: $detail';
}

/// The network is a real boundary, so this is an interface: [LichessStudyWriterApi]
/// in the app, a scripted one in tests.
abstract interface class LichessStudyWriter {
  /// Whether a token is saved at all; a write without one cannot succeed.
  Future<bool> get signedIn;

  /// A new private study called [name]; its id when made.
  Future<LichessWrite> create(String name);

  /// [pgn], one game, as a new chapter of [study] called [name] and seen
  /// from [orientation]; the chapter's id when made. [initial] takes the
  /// place of the empty chapter a new study starts with.
  Future<LichessWrite> addChapter(
    String study, {
    required String pgn,
    required String name,
    required Side orientation,
    bool initial = false,
  });

  /// The moves of [pgn] in place of chapter [chapter]'s, then its [tags]:
  /// the chapter keeps its id, name and place in the study.
  Future<LichessWrite> replaceChapter(
    String study,
    String chapter, {
    required String pgn,
    required Map<String, String> tags,
  });
}

/// How long one write may take before it counts as not arriving.
const studyWriteTimeout = Duration(seconds: 30);

final class LichessStudyWriterApi implements LichessStudyWriter {
  LichessStudyWriterApi(this._client, {required this._token, Uri? site})
    : site = site ?? Uri.https('lichess.org');

  final http.Client _client;
  final Future<String?> Function() _token;

  /// Where Lichess is; another site only for a local Lichess in a test.
  final Uri site;

  @override
  Future<bool> get signedIn async => (await _token())?.isNotEmpty ?? false;

  @override
  Future<LichessWrite> create(String name) =>
      _post('create a Lichess study', '/api/study', {
        'name': name,
        'visibility': 'private',
        'computer': 'everyone',
        'explorer': 'everyone',
        'cloneable': 'everyone',
        'shareable': 'everyone',
        'chat': 'member',
      }, id: (json) => json['id'] as String?);

  @override
  Future<LichessWrite> addChapter(
    String study, {
    required String pgn,
    required String name,
    required Side orientation,
    bool initial = false,
  }) => _post(
    'add a chapter to the Lichess study $study',
    '/api/study/${Uri.encodeComponent(study)}/import-pgn',
    {
      'pgn': pgn,
      'name': name,
      'orientation': orientation == Side.white ? 'white' : 'black',
      if (initial) 'initial': 'true',
    },
    id: (json) {
      final chapters = json['chapters'];
      final first = chapters is List ? chapters.firstOrNull : null;
      return first is Map ? first['id'] as String? : null;
    },
  );

  @override
  Future<LichessWrite> replaceChapter(
    String study,
    String chapter, {
    required String pgn,
    required Map<String, String> tags,
  }) async {
    final path =
        '/api/study/${Uri.encodeComponent(study)}/'
        '${Uri.encodeComponent(chapter)}';
    final moved = await _post(
      'replace the moves of the Lichess chapter $study/$chapter',
      '$path/moves',
      {'pgn': pgn},
    );
    if (moved is LichessNotWritten || tags.isEmpty) return moved;
    final header = [
      for (final MapEntry(:key, :value) in tags.entries)
        '[$key "${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"]',
    ].join('\n');
    return _post(
      'set the tags of the Lichess chapter $study/$chapter',
      '$path/tags',
      {'pgn': header},
    );
  }

  Future<LichessWrite> _post(
    String what,
    String path,
    Map<String, String> form, {
    String? Function(Map<String, Object?>)? id,
  }) async {
    final token = await _token();
    if (token == null || token.isEmpty) {
      return const LichessNotWritten(LichessWriteProblem.signedOut);
    }
    final http.Response response;
    try {
      response = await _client
          .post(
            site.replace(path: path),
            headers: lichessHeaders(token: token, accept: 'application/json'),
            body: form,
          )
          .timeout(studyWriteTimeout);
    } on Object catch (error) {
      log.w(what, error.runtimeType);
      return const LichessNotWritten(LichessWriteProblem.unreachable);
    }
    final status = response.statusCode;
    final body = const Utf8Decoder(
      allowMalformed: true,
    ).convert(response.bodyBytes);
    final json = _json(body);
    if (status >= 200 && status < 300) {
      // Lichess answers a chapter it could not read, or a study the user
      // may not add to, with 200 and an error.
      final error = json?['error'];
      if (error is String && error.isNotEmpty) {
        log.w(what, 'Lichess said: $error');
        return error.contains('permission')
            ? const LichessNotWritten(LichessWriteProblem.notFound)
            : LichessNotWritten(LichessWriteProblem.rejected, detail: error);
      }
      final made = json == null ? null : id?.call(json);
      if (id != null && made == null) {
        log.w(what, 'Lichess made nothing');
        return const LichessNotWritten(LichessWriteProblem.notFound);
      }
      return LichessWritten(made);
    }
    log.w(what, 'HTTP $status');
    return LichessNotWritten(switch (status) {
      401 || 403 => LichessWriteProblem.permission,
      404 => LichessWriteProblem.notFound,
      429 => LichessWriteProblem.limited,
      400 when _forbiddenChapter(json) => LichessWriteProblem.notFound,
      400 => LichessWriteProblem.rejected,
      _ => LichessWriteProblem.http,
    }, detail: status == 400 ? _error(json) : null);
  }

  static Map<String, Object?>? _json(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, Object?> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  /// Lichess answers a chapter that is gone, or not the user's to change,
  /// with a 400 that says so.
  static bool _forbiddenChapter(Map<String, Object?>? json) =>
      _error(json)?.startsWith('Invalid or forbidden chapter') ?? false;

  /// The reason in a 400: a sentence, or the first of a form's field errors.
  static String? _error(Map<String, Object?>? json) {
    final error = json?['error'];
    if (error is String) return error;
    if (error is Map) {
      for (final value in error.values) {
        if (value is List && value.isNotEmpty) return '${value.first}';
        if (value is String) return value;
      }
    }
    return null;
  }
}

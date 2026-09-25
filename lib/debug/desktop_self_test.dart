// Opt-in checks inside the actual release executable. All documents, backups
// and extracted engines live in a disposable profile, never the user's data.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

import '../v2/app/app.dart';
import '../v2/app/environment.dart';
import '../v2/app/exit_guard.dart';
import '../v2/chess/fen.dart';
import '../v2/chess/pgn/game_tree.dart';
import '../v2/engines/engine_supervisor.dart';
import '../v2/engines/maia/move_policy.dart';
import '../v2/net/lichess_login.dart';
import '../v2/storage/chapter_files.dart';
import '../v2/storage/pgn_document_store.dart';
import '../v2/storage/pgn_file_store.dart';
import '../v2/workspace/document_saver.dart';
import '../v2/workspace/document_session.dart';
import '../v2/workspace/session_results.dart';

const desktopSelfTestFlag = '--self-test-desktop';
const desktopReportMarker = 'CAP_DESKTOP_REPORT=';

/// Empty means print the report only; an explicit path is useful for Windows
/// GUI executables whose parent does not capture standard output.
String? desktopReportPath(List<String> args) {
  for (final arg in args) {
    if (arg == desktopSelfTestFlag) return '';
    if (arg.startsWith('$desktopSelfTestFlag=')) {
      return arg.substring(desktopSelfTestFlag.length + 1);
    }
  }
  return null;
}

Future<Never> runDesktopSelfTest(String reportPath) async {
  final report = await checkDesktop();
  final json = jsonEncode(report);
  if (reportPath.isNotEmpty) {
    await File(reportPath).writeAsString(json, flush: true);
  }
  stdout.writeln('$desktopReportMarker$json');
  await stdout.flush();
  exit(report['ok'] == true ? 0 : 1);
}

Future<Map<String, Object?>> checkDesktop() async {
  final report = <String, Object?>{
    'os': Platform.operatingSystemVersion,
    'executable': Platform.resolvedExecutable,
    'ok': false,
  };
  final root = await Directory.systemTemp.createTemp('cap-desktop-check-');
  final support = Directory(p.join(root.path, 'José 棋', 'Support'));
  final documents = Directory(p.join(root.path, 'José 棋', 'Documents'));
  final engines = EngineSupervisor();
  final maia = MaiaLaunch();
  var step = 'documents';
  try {
    await _documents(documents, support);
    report[step] = true;
    step = 'stockfish';
    await _stockfish(support, engines);
    report[step] = true;
    step = 'maia';
    final policy = await maia
        .policy(Fen.initial, 1500)
        .timeout(const Duration(seconds: 60));
    _require(
      policy is MaiaPolicy && policy.shares.length == 20,
      policy is MaiaFailed
          ? policy.reason
          : 'Maia did not score the legal moves',
    );
    report[step] = true;
    step = 'loginSockets';
    await _loginSockets();
    report[step] = true;
    report['ok'] = true;
  } on Object catch (error, stack) {
    report['failure'] = '$step: $error';
    report['stack'] = '$stack';
  } finally {
    maia.dispose();
    await engines.dispose();
    await root.delete(recursive: true);
  }
  return report;
}

Future<void> _documents(Directory documents, Directory support) async {
  // Cross MAX_PATH using legal individual components, on every platform.
  final ref = ChapterRef.at(
    p.join(documents.path, 'a' * 110, 'b' * 110, '${'c' * 100}.pgn'),
  );
  final store = PgnFileStore(documents: documents, support: support);
  const original = '[Event "Desktop check"]\n[Result "*"]\n\n1. e4 *\n';
  final created = await store.create(ref, original);
  _require(created is Created, 'Create failed: $created');
  final saver = DocumentSaver(store, delay: const Duration(minutes: 1));
  final session = DocumentSession(store, saver);
  try {
    _require(await session.open(ref) is DocumentOpened, 'Open failed');
    session.setComment(NodePath.of([0]), 'Saved before exit 棋');
    _require(!saver.settled, 'The edit did not become a pending save');
    final quitting = AppExit(
      guard: ExitGuard(saver: saver, question: _NoQuestion()),
      stopEngines: () async {},
      closeLog: () async {},
    );
    _require(await quitting.leave() == AppExitResponse.exit, 'Exit refused');
    quitting.closing.dispose();
    final reopened = PgnFileStore(documents: documents, support: support);
    final read = await reopened.open(ref);
    _require(
      read is Opened && read.text.contains('Saved before exit 棋'),
      'Reopen lost the last edit',
    );
    final moved = await reopened.rename(
      ref,
      'Renamed 棋.pgn',
      expected: (read as Opened).revision,
    );
    _require(moved is Moved, 'Rename failed: $moved');
    final renamed = ChapterRef.at(p.join(p.dirname(ref.path), 'Renamed 棋.pgn'));
    final deleted = await reopened.delete(renamed, expected: read.revision);
    _require(deleted is Deleted, 'Recoverable delete failed: $deleted');
    _require(
      (await File(
        (deleted as Deleted).recoveredTo,
      ).readAsString()).contains('Saved before exit 棋'),
      'Recovery lost the edit',
    );
  } finally {
    session.dispose();
    saver.dispose();
  }
}

Future<void> _stockfish(Directory support, EngineSupervisor engines) async {
  final started = await launchStockfish(
    support: support,
    engines: engines,
    cores: 1,
    memoryMb: 16,
  );
  _require(
    started is Started,
    started is StartFailed ? started.reason : 'Stockfish did not start',
  );
  final engine = (started as Started).engine;
  final lines = await engine
      .analyse(Fen.initial, multiPv: 1, depth: 4)
      .lines
      .toList()
      .timeout(const Duration(seconds: 30));
  _require(
    lines.any((line) => line.pv.isNotEmpty),
    'Stockfish returned no moves',
  );
  await engine.quit();
  _require(engines.pids.isEmpty, 'Stockfish did not exit');
}

Future<void> _loginSockets() async {
  // The provider is scripted; the callback is a real incoming/outgoing socket
  // in the signed app, exercising both macOS network entitlements offline.
  final provider = MockClient(
    (request) async => request.url.path == '/api/token'
        ? http.Response('{"access_token":"self-test","expires_in":60}', 200)
        : http.Response('{"username":"self-test"}', 200),
  );
  final login = LichessLoginApi(
    provider,
    wait: const Duration(seconds: 5),
    openBrowser: (page) async {
      final redirect = Uri.parse(page.queryParameters['redirect_uri']!);
      final client = HttpClient();
      try {
        final request = await client.getUrl(
          redirect.replace(
            queryParameters: {
              'state': page.queryParameters['state']!,
              'code': 'self-test',
            },
          ),
        );
        final response = await request.close();
        await response.drain<void>();
        return response.statusCode == 200;
      } finally {
        client.close(force: true);
      }
    },
  );
  try {
    final result = await login.logIn(waiting: (_, {required opened}) {});
    _require(
      result is LoggedIn,
      result is LoginFailed ? result.problem.sentence : 'Login callback failed',
    );
  } finally {
    await login.cancel();
    provider.close();
  }
}

void _require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

final class _NoQuestion implements DraftQuestion {
  @override
  Future<DraftChoice?> put(DraftPrompt prompt) => throw StateError(prompt.body);
  @override
  void withdraw() {}
}

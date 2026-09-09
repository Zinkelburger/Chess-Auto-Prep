/// [SnapshotExporter] as a unit: the guards that refuse an export, the name
/// it suggests, and the real export path against a small headless build
/// (the only way `TreeBuildService.currentTree` gets set).
///
/// No engine is started: the headless config is `maiaDbExplore`, which stops
/// on the first database miss — and `flutter test` answers every socket with
/// an empty 400, so the tree stays at its root.
library;

import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/core/generation_progress.dart';
import 'package:chess_auto_prep/core/generation_session_types.dart';
import 'package:chess_auto_prep/core/snapshot_exporter.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:chess_auto_prep/services/storage/storage_service.dart';
import 'package:chess_auto_prep/services/tree_build_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryStorage implements StorageService {
  final Map<String, String> files = {};
  int writes = 0;

  @override
  Future<String> repertoireFilePath(String name) async => '/reps/$name.pgn';

  @override
  Future<bool> fileExists(String path) async => files.containsKey(path);

  @override
  Future<void> writeFile(
    String path,
    String content, {
    bool createOnly = false,
    String? expectedContent,
  }) async {
    writes++;
    files[path] = content;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not used here');
}

/// [rankLinesByImportance] is off by default here because the on-by-default
/// setting trips a bug in `snapshot_export.dart` on an empty snapshot (see
/// the skipped test below); the exporter's own behaviour is what these test.
TreeBuildConfig _headlessConfig({bool rankLinesByImportance = false}) =>
    TreeBuildConfig(
      startFen: kStandardStartFen,
      playAsWhite: true,
      buildMode: BuildMode.maiaDbExplore,
      relativeEval: false,
      coverMinProb: 0,
      maxPly: 2,
      rankLinesByImportance: rankLinesByImportance,
    );

/// Everything the exporter reads through its suppliers, as plain fields.
class _Session {
  bool generating = false;
  bool paused = false;
  bool cancelRequested = false;
  GenerationRequest? request;
  TreeBuildConfig? config;
  List<String> startMoves = const [];
  final buildService = TreeBuildService();
  int notifications = 0;

  late final GenerationProgress progress = GenerationProgress(
    notify: () {},
    job: () => null,
    isRunning: () => generating,
    isPaused: () => paused,
    elapsed: Stopwatch.new,
  );

  late final SnapshotExporter exporter = SnapshotExporter(
    notify: () => notifications++,
    isGenerating: () => generating,
    isPaused: () => paused,
    cancelRequested: () => cancelRequested,
    activeRequest: () => request,
    activeConfig: () => config,
    startMoveSequence: () => startMoves,
    buildService: () => buildService,
    progress: () => progress,
  );

  /// Put the session in the state a mid-BFS export finds it in.
  void midBuild({
    required String repertoirePath,
    bool rankLinesByImportance = false,
  }) {
    generating = true;
    progress.phase = GenerationPhase.buildingTree;
    config = _headlessConfig(rankLinesByImportance: rankLinesByImportance);
    request = GenerationRequest(
      config: config!,
      repertoireFilePath: repertoirePath,
      buildRootFen: kStandardStartFen,
      lineMovePrefix: const [],
      repertoireStartFen: kStandardStartFen,
      onLinesSaved: (_) {},
    );
  }

  /// Run a headless build so `buildService.currentTree` is set.
  Future<void> buildTree() => buildService.build(
    config: _headlessConfig(),
    isCancelled: () => false,
    onProgress: (_) {},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MemoryStorage storage;
  setUp(() {
    storage = _MemoryStorage();
    StorageFactory.instanceForTest = storage;
  });
  tearDown(() => StorageFactory.instanceForTest = null);

  group('nameSuggestion', () {
    test('is built from the repertoire file and the current depth', () {
      final s = _Session()..midBuild(repertoirePath: '/reps/Najdorf.pgn');
      s.progress.depth = 7;
      expect(s.exporter.nameSuggestion(), 'Najdorf d7 snapshot');
    });

    test('falls back to "Generated" with no active request', () {
      final s = _Session();
      expect(s.exporter.nameSuggestion(), 'Generated d0 snapshot');
    });
  });

  group('refusals', () {
    test('nothing to export when no build is running', () async {
      final s = _Session();
      final (ok, message) = await s.exporter.export(
        repertoireName: 'x',
        verify: false,
      );
      expect(ok, isFalse);
      expect(message, 'No active build to export from.');
      expect(s.exporter.isExporting, isFalse);
      expect(s.exporter.status, isNull);
      expect(storage.writes, 0);
    });

    test('a build past the tree phase cannot be snapshotted', () async {
      final s = _Session()..midBuild(repertoirePath: '/r.pgn');
      s.progress.phase = GenerationPhase.verifying;
      final (ok, message) = await s.exporter.export(
        repertoireName: 'x',
        verify: false,
      );
      expect(ok, isFalse);
      expect(message, 'No active build to export from.');
    });

    test('a cancelling build cannot be snapshotted', () async {
      final s = _Session()..midBuild(repertoirePath: '/r.pgn');
      s.cancelRequested = true;
      final (ok, _) = await s.exporter.export(
        repertoireName: 'x',
        verify: false,
      );
      expect(ok, isFalse);
    });

    test('a build whose tree is not up yet asks to retry', () async {
      final s = _Session()..midBuild(repertoirePath: '/r.pgn');
      final (ok, message) = await s.exporter.export(
        repertoireName: 'x',
        verify: false,
      );
      expect(ok, isFalse);
      expect(message, 'Build state unavailable — try again in a moment.');
    });

    test('a blank name is refused before any storage is touched', () async {
      final s = _Session()..midBuild(repertoirePath: '/r.pgn');
      await s.buildTree();
      final (ok, message) = await s.exporter.export(
        repertoireName: '   ',
        verify: false,
      );
      expect(ok, isFalse);
      expect(message, 'Please enter a repertoire name.');
      expect(storage.writes, 0);
    });

    test('never overwrites a repertoire of the same name', () async {
      final s = _Session()..midBuild(repertoirePath: '/r.pgn');
      await s.buildTree();
      storage.files['/reps/Mine.pgn'] = 'precious';
      final (ok, message) = await s.exporter.export(
        repertoireName: ' Mine ',
        verify: false,
      );
      expect(ok, isFalse);
      expect(message, 'A repertoire named "Mine" already exists.');
      expect(storage.files['/reps/Mine.pgn'], 'precious');
      expect(storage.writes, 0);
    });
  });

  group('export against a live tree', () {
    test('a root-only tree reports no lines and leaves state clean', () async {
      final s = _Session()..midBuild(repertoirePath: '/r.pgn');
      await s.buildTree();
      expect(s.buildService.currentTree, isNotNull);

      final (ok, message) = await s.exporter.export(
        repertoireName: 'Snap',
        verify: false,
      );

      expect(ok, isFalse);
      expect(
        message,
        'Snapshot produced no lines yet — let the build explore deeper.',
      );
      expect(storage.writes, 0, reason: 'no file for an empty snapshot');
      expect(s.exporter.isExporting, isFalse);
      expect(s.exporter.status, isNull);
      expect(s.notifications, greaterThan(0));
      expect(s.buildService.isPaused, isFalse);
    });

    // Regression: `LinePruner.take` used to return `const []` when nothing
    // survived and `snapshotLines` sorted it in place, so the user saw
    // "Unsupported operation" instead of "no lines yet".
    test(
      'an empty snapshot with importance ranking on still says "no lines"',
      () async {
        final s = _Session()
          ..midBuild(repertoirePath: '/r.pgn', rankLinesByImportance: true);
        await s.buildTree();
        final (_, message) = await s.exporter.export(
          repertoireName: 'Snap',
          verify: false,
        );
        expect(
          message,
          'Snapshot produced no lines yet — let the build explore deeper.',
        );
      },
    );

    test('an unverified export never pauses the build', () async {
      final s = _Session()..midBuild(repertoirePath: '/r.pgn');
      await s.buildTree();
      var sawPause = false;
      final exporting = s.exporter.export(
        repertoireName: 'Snap',
        verify: false,
      );
      // Poll while the isolate runs.
      while (s.exporter.isExporting) {
        if (s.buildService.isPaused) sawPause = true;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await exporting;
      expect(sawPause, isFalse);
    });

    test('a second export while one is running is refused', () async {
      final s = _Session()..midBuild(repertoirePath: '/r.pgn');
      await s.buildTree();

      // No await between the two calls: the second must see the first's
      // claim on the exporter even though the first has not finished its
      // storage checks yet.
      final first = s.exporter.export(repertoireName: 'A', verify: false);
      final second = s.exporter.export(repertoireName: 'B', verify: false);

      final (_, secondMessage) = await second;
      await first;
      expect(secondMessage, 'A snapshot export is already running.');
    });
  });
}

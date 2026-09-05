import 'dart:io';
import 'dart:async';
import 'dart:isolate';
import 'dart:convert';
import 'package:chess_auto_prep/services/analysis/player_corpus_store.dart';
import 'package:chess_auto_prep/models/analysis_player_info.dart';
import 'package:chess_auto_prep/models/repertoire_review_entry.dart';
import 'package:chess_auto_prep/utils/training_csv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:chess_auto_prep/services/game_store/game_store.dart';
import 'package:chess_auto_prep/services/game_store/game_store_service.dart';
import 'package:chess_auto_prep/services/analysis_games_service.dart';
import 'package:chess_auto_prep/features/tactics/services/tactics_database.dart';
import 'package:chess_auto_prep/features/tactics/models/tactics_position.dart';
import 'package:chess_auto_prep/utils/atomic_file.dart';
import 'package:chess_auto_prep/core/pgn_viewer_controller.dart';
import 'package:chess_auto_prep/services/game_analysis_controller.dart';
import 'package:chess_auto_prep/widgets/pgn_viewer_widget.dart';
import 'package:chess_auto_prep/models/repertoire_move_progress.dart';
import 'package:chess_auto_prep/models/repertoire_review_history_entry.dart';
import 'package:chess_auto_prep/services/repertoire_review_service.dart';
import 'package:chess_auto_prep/services/games_library/game_filter.dart';
import 'package:chess_auto_prep/utils/safe_file_name.dart';
import 'package:chess_auto_prep/core/study_controller.dart';
import 'package:chess_auto_prep/features/tactics/services/tactics_import_service.dart';

class Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => '$root/support';
}

class FailingStorage extends IOStorageService {
  @override
  Future<void> writeFile(
    String path,
    String content, {
    bool createOnly = false,
    String? expectedContent,
  }) async {
    throw const FileSystemException('injected disk full');
  }
}

class FakeAnalysis extends GameAnalysisController {
  @override
  Future<bool> tryLoadFromPgn(String text) async => true;
  @override
  void cancel() {}
}

class UnreadableTactics extends IOStorageService {
  @override
  Future<String?> readFile(String path) async =>
      path.endsWith('Default.pgn') ? null : super.readFile(path);
}

const fen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
TacticsPosition puzzle() => const TacticsPosition(
  fen: fen,
  gameWhite: 'A',
  gameBlack: 'B',
  gameResult: '*',
  gameDate: '2026.09.04',
  gameId: 'game1',
  userMove: 'd4',
  correctLine: ['e4'],
  mistakeType: '??',
  mistakeAnalysis: 'audit',
);
String game(String moves, {String site = 'Local', String round = '1'}) =>
    '[Event "Audit"]\n[Site "$site"]\n[Date "2026.09.04"]\n[Round "$round"]\n[White "A"]\n[Black "B"]\n[Result "*"]\n\n$moves *';

Future<void> pausedWriter((String, SendPort) request) async {
  final resume = ReceivePort();
  final writer = AtomicFileWriter(
    testHook: (step) async {
      if (step == AtomicWriteStep.beforePrimaryReplace) {
        request.$2.send(resume.sendPort);
        await resume.first;
        resume.close();
      }
    },
  );
  try {
    await writer.writeText(
      File(request.$1),
      'writer A',
      expectedContent: 'old',
    );
    request.$2.send('done');
  } catch (e) {
    request.$2.send('error: $e');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform original;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('chess-important-audit-');
    await Directory('${root.path}/support').create();
    original = PathProviderPlatform.instance;
    PathProviderPlatform.instance = Paths(root.path);
    StorageFactory.instanceForTest = IOStorageService();
    GameStoreService.setTestInstance(
      GameStoreService(
        dbPathProvider: () async => '${root.path}/support/app_games.db',
      ),
    );
  });
  tearDown(() async {
    GameStoreService.instance.close();
    GameStoreService.setTestInstance(GameStoreService());
    StorageFactory.instanceForTest = null;
    PathProviderPlatform.instance = original;
    await root.delete(recursive: true);
  });

  test(
    'Regression: distinct rounds with the same players and date survive',
    () async {
      final store = await GameStoreService.instance.open();
      final result = store.importPgn(
        '${game('1. e4 e5')}\n\n${game('1. d4 d5', round: '2')}',
        collection: 'audit',
      );
      expect(result.inserted, 2);
      expect(result.updated, 0);
      expect(store.count('audit'), 2);
      expect(store.exportPgn('audit'), contains('1. d4 d5'));
      expect(store.exportPgn('audit'), contains('1. e4 e5'));
    },
  );

  test(
    'Regression: a tournament URL cannot identify an individual game',
    () async {
      final store = await GameStoreService.instance.open();
      final a = game('1. e4 e5', site: 'https://example.org/tournament');
      final b = game(
        '1. d4 d5',
        site: 'https://example.org/tournament',
      ).replaceAll('[White "A"]', '[White "C"]');
      store.importPgn('$a\n\n$b', collection: 'audit');
      expect(store.count('audit'), 2);
    },
  );

  test(
    'Regression: tactics write failure propagates and leaves completion unset',
    () async {
      StorageFactory.instanceForTest = FailingStorage();
      final db = TacticsDatabase();
      await expectLater(
        db.addPosition(puzzle()),
        throwsA(isA<FileSystemException>()),
      );
      expect(db.lastWriteError, isNotNull);
      expect(
        await File('${root.path}/tactics_sets/Default.pgn').exists(),
        isFalse,
      );
      expect(db.isGameAnalyzed('game1'), isFalse);
      expect(await File('${root.path}/analyzed_games.txt').exists(), isFalse);
      db.dispose();
    },
  );

  test(
    'Regression: deleting a player preserves similarly named players',
    () async {
      final service = AnalysisGamesService();
      await service.saveAnalysisGames(
        game('1. e4 e5'),
        platform: 'import',
        username: 'alice',
        maxGames: 100,
      );
      await service.saveAnalysisGames(
        game('1. d4 d5'),
        platform: 'import',
        username: 'alice_white_analysis',
        maxGames: 100,
      );
      final path = await service.analysisPgnPath(
        'import',
        'alice_white_analysis',
      );
      expect(
        (await service.getAllCachedPlayers()).map((p) => p.username),
        contains('alice_white_analysis'),
      );
      await service.deletePlayerData('import', 'alice');
      expect(await File(path).exists(), isTrue);
      expect(await service.loadAnalysisGames('import', 'alice'), isNull);
      expect((await service.getAllCachedPlayers()).map((p) => p.username), [
        'alice_white_analysis',
      ]);
    },
  );

  test(
    'Regression: replacing player games invalidates old engine evals',
    () async {
      final service = AnalysisGamesService();
      await service.saveAnalysisGames(
        game('1. e4 e5'),
        platform: 'import',
        username: 'alice',
        maxGames: 100,
      );
      await service.saveEngineEvals('import', 'alice', [
        {'source': 'old games'},
      ]);
      await service.saveAnalysisGames(
        game('1. d4 d5'),
        platform: 'import',
        username: 'alice',
        maxGames: 100,
      );
      expect(await service.loadEngineEvals('import', 'alice'), isNull);
    },
  );

  test('Regression: read recovery waits for a live replacement', () async {
    final file = File('${root.path}/test.pgn');
    await file.writeAsString('old complete document');
    Future<String?>? reader;
    final writer = AtomicFileWriter(
      forceBackupSwapForTesting: true,
      testHook: (step) async {
        if (step == AtomicWriteStep.beforeBackup) {
          reader = StorageFactory.instance.readFile(file.path);
        }
      },
    );
    await writer.writeText(file, 'new complete document');
    expect(await reader, 'new complete document');
    expect(await file.readAsString(), 'new complete document');
  });

  test(
    'Regression: partially decoded tactics cannot overwrite the original',
    () async {
      final file = File('${root.path}/tactics_sets/Default.pgn');
      await file.parent.create();
      final valid = '${game('1. e4')}\n';
      final validFen = valid.replaceFirst(
        '[Result "*"]',
        '[Result "*"]\n[FEN "$fen"]\n[SetUp "1"]',
      );
      final damaged = validFen
          .replaceAll(fen, 'damaged FEN')
          .replaceAll('[Event "Audit"]', '[Event "valuable damaged record"]');
      await file.writeAsString('$validFen\n$damaged');
      final db = TacticsDatabase();
      expect(await db.loadPositions(), 1);
      await expectLater(db.savePositions(), throwsStateError);
      expect(await file.readAsString(), contains('valuable damaged record'));
      db.dispose();
    },
  );

  test(
    'Regression: isolate writers serialize and reject stale expected content',
    () async {
      final file = File('${root.path}/isolate.pgn');
      await file.writeAsString('old');
      final receive = ReceivePort();
      final ready = Completer<SendPort>();
      final done = Completer<String>();
      receive.listen((message) {
        if (message is SendPort) {
          ready.complete(message);
        } else {
          done.complete(message.toString());
        }
      });
      await Isolate.spawn(pausedWriter, (file.path, receive.sendPort));
      final resume = await ready.future.timeout(const Duration(seconds: 10));
      var finished = false;
      final second = AtomicFileWriter().writeText(
        file,
        'writer B',
        expectedContent: 'old',
      );
      final checked = expectLater(
        second,
        throwsA(isA<AtomicWriteConflict>()),
      ).then((_) => finished = true);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(finished, isFalse);
      resume.send(true);
      expect(await done.future.timeout(const Duration(seconds: 10)), 'done');
      await checked;
      expect(await file.readAsString(), 'writer A');
      receive.close();
    },
  );

  test(
    'Regression: rating one game preserves games appended on disk',
    () async {
      final file = File('${root.path}/viewer.pgn');
      final originalGame = game('1. e4 e5');
      await file.writeAsString(originalGame);
      final analysis = FakeAnalysis();
      final c = PgnViewerController(
        pgnWidgetController: PgnViewerWidgetController(),
        analysisController: analysis,
      );
      final entry = PgnGameEntry(
        headers: {'Event': 'Audit', 'White': 'A', 'Black': 'B'},
        pgnText: originalGame,
      );
      c.filePath = file.path;
      c.allGames = [entry];
      c.filteredGames = [entry];
      await file.writeAsString(
        '$originalGame\n\n${game('1. d4 d5', round: '2')}',
      );
      c.setRating(5);
      await c.doPersistMetadata();
      expect(await file.readAsString(), contains('1. d4 d5'));
      expect(await file.readAsString(), contains('[StudyRating'));
      c.filePath = null;
      c.dispose();
      analysis.dispose();
    },
  );

  test(
    'Regression: commas in repertoire paths roundtrip through progress and history',
    () async {
      expect(requireSafeFileName('French, main'), 'French, main');
      final progress = RepertoireMoveProgress(
        repertoireId: '${root.path}/repertoires/French, main/Main.pgn',
        lineId: 'line1',
        moveIndex: 3,
        correctStreak: 2,
        learned: false,
      );
      final svc = RepertoireReviewService();
      await svc.saveMoveProgress([progress]);
      expect(
        (await svc.loadMoveProgress()).single.repertoireId,
        progress.repertoireId,
      );
      final history = RepertoireReviewHistoryEntry(
        repertoireId: progress.repertoireId,
        lineId: 'line1',
        timestampUtc: DateTime.utc(2026),
        rating: 'good',
        hadMistake: false,
      );
      await svc.appendHistory([history]);
      expect(
        (await svc.loadHistory()).single.repertoireId,
        progress.repertoireId,
      );
    },
  );

  test(
    'Regression: overlapping review appends preserve both history entries',
    () async {
      final storage = IOStorageService();
      final svc = RepertoireReviewService(storage: storage);
      RepertoireReviewHistoryEntry row(String id) =>
          RepertoireReviewHistoryEntry(
            repertoireId: 'rep',
            lineId: id,
            timestampUtc: DateTime.utc(2026),
            rating: 'good',
            hadMistake: false,
          );
      await Future.wait([
        svc.appendHistory([row('A')]),
        svc.appendHistory([row('B')]),
      ]);
      expect((await svc.loadHistory()).length, 2);
    },
  );

  test('Regression: cache limits retain locally annotated games', () {
    final annotated = game(
      '1. e4 {my irreplaceable note} e5',
    ).replaceAll('2026.09.04', '2026.09.01');
    final newer = game('1. d4 d5').replaceAll('2026.09.04', '2026.09.02');
    final latest = game('1. c4 e5');
    final merged = mergeGamePgns(
      existing: '$annotated\n\n$newer',
      fresh: latest,
      maxGames: 2,
    );
    expect(merged, contains('my irreplaceable note'));
    expect(merged, contains('1. c4 e5'));
  });

  test(
    'Regression: study navigation stops when unsaved edits conflict',
    () async {
      final c = StudyController();
      await c.newStudy('First');
      final first = File(c.doc.filePath!);
      c.addChapter('unsaved irreplaceable chapter');
      await first.writeAsString(game('1. d4 d5'));
      final second = File('${root.path}/second.pgn');
      await second.writeAsString(game('1. e4 e5'));
      await c.openStudy(second.path);
      expect(c.doc.filePath, first.path);
      expect(c.saveError, isNotNull);
      expect(
        c.doc.chapters.any((ch) => ch.name == 'unsaved irreplaceable chapter'),
        isTrue,
      );
      expect(
        await first.readAsString(),
        isNot(contains('unsaved irreplaceable chapter')),
      );
      c.dispose();
    },
  );

  test(
    'Regression: failed reference reads prevent pruning source games',
    () async {
      final db = TacticsDatabase();
      await db.addPosition(puzzle());
      final store = await GameStoreService.instance.open();
      final source = game(
        '1. e4 e5',
      ).replaceFirst('[Result "*"]', '[Result "*"]\n[GameId "game1"]');
      store.importPgn(source, collection: GameCollections.tactics);
      StorageFactory.instanceForTest = UnreadableTactics();
      db.analyzedGameIds.add('game1');
      await expectLater(
        TacticsImportService(database: db).pruneStoredPgns(),
        throwsStateError,
      );
      expect(store.count(GameCollections.tactics), 1);
      expect(
        await File('${root.path}/tactics_sets/Default.pgn').readAsString(),
        contains('[GameId "game1"]'),
      );
      db.dispose();
    },
  );
  test('completed game and puzzles survive one durable checkpoint', () async {
    final db = TacticsDatabase();
    await db.commitAnalyzedGame('game1', [puzzle()]);
    await db.commitAnalyzedGame('no-puzzles', []);
    final reopened = TacticsDatabase();
    await reopened.loadPositions();
    expect(reopened.positions, hasLength(1));
    expect(reopened.analyzedGameIds, containsAll(['game1', 'no-puzzles']));
    db.dispose();
    reopened.dispose();
  });

  test('failed completed-game commit cannot persist its completion', () async {
    final db = TacticsDatabase();
    StorageFactory.instanceForTest = FailingStorage();
    await expectLater(
      db.commitAnalyzedGame('game1', [puzzle()]),
      throwsA(isA<FileSystemException>()),
    );
    expect(db.isGameAnalyzed('game1'), isFalse);
    StorageFactory.instanceForTest = IOStorageService();
    final reopened = TacticsDatabase();
    await reopened.loadPositions();
    expect(reopened.isGameAnalyzed('game1'), isFalse);
    db.dispose();
    reopened.dispose();
  });

  test(
    'training merge preserves another repertoire and rejects stale same-line edits',
    () async {
      RepertoireReviewEntry entry(String path) => RepertoireReviewEntry(
        repertoireId: path,
        lineId: 'line',
        lineName: 'Line',
      );
      final seed = RepertoireReviewService();
      await seed.saveAll([entry('a'), entry('b')]);
      final first = RepertoireReviewService();
      final second = RepertoireReviewService();
      final a = await first.loadAll();
      final b = await second.loadAll();
      await first.saveAll([a.first.copyWith(passCount: 1)], repertoireId: 'a');
      await second.saveAll([b.last.copyWith(passCount: 2)], repertoireId: 'b');
      final actual = await seed.loadAll();
      expect(actual.map((e) => e.passCount), [1, 2]);
      await expectLater(
        second.saveAll([b.first.copyWith(passCount: 3)], repertoireId: 'a'),
        throwsStateError,
      );
      expect((await seed.loadAll()).first.passCount, 1);
    },
  );

  test(
    'legacy unquoted comma paths are repaired and raw CSV is backed up',
    () async {
      const raw =
          'repertoire_id,line_id,move_index,correct_streak,learned\nFrench, main,line1,3,2,0\n';
      await File(
        '${root.path}/repertoire_move_progress.csv',
      ).writeAsString(raw);
      final service = RepertoireReviewService();
      final entries = await service.loadMoveProgress();
      expect(entries.single.repertoireId, 'French, main');
      await service.saveMoveProgress(entries);
      expect(
        await File(
          '${root.path}/repertoire_move_progress.csv.pre-csv-v2.bak',
        ).readAsString(),
        raw,
      );
      expect((await service.loadMoveProgress()).single.moveIndex, 3);
    },
  );

  test('quoted multiline CSV fields preserve exact content', () {
    const cells = ['French, main', 'id', 'a "quote"\nand a line  '];
    expect(decodeTrainingRow(encodeTrainingRow(cells), 3), cells);
  });

  test(
    'failure before publishing a player generation leaves the old corpus active',
    () async {
      const info = AnalysisPlayerInfo(platform: 'import', username: 'alice');
      final store = PlayerCorpusStore();
      final original = await store.save(info, game('1. e4 e5'));
      var writes = 0;
      final failing = PlayerCorpusStore(
        writer: AtomicFileWriter(
          testHook: (step) async {
            if (step == AtomicWriteStep.tempFlushed && ++writes == 3) {
              throw const FileSystemException('injected manifest failure');
            }
          },
        ),
      );
      await expectLater(
        failing.save(info, game('1. d4 d5')),
        throwsA(isA<FileSystemException>()),
      );
      final loaded = await store.load('import', 'alice');
      expect(loaded!.revision, original.revision);
      expect(await File(loaded.pgnPath).readAsString(), game('1. e4 e5'));
    },
  );

  test(
    'unavailable SQLite index does not undo a published player corpus',
    () async {
      GameStoreService.instance.close();
      GameStoreService.setTestInstance(
        GameStoreService(dbPathProvider: () async => root.path),
      );
      final store = PlayerCorpusStore();
      final corpus = await store.save(
        const AnalysisPlayerInfo(platform: 'import', username: 'alice'),
        game('1. e4 e5'),
      );
      expect(corpus.info.storageWarning, contains('unavailable'));
      expect(await File(corpus.pgnPath).readAsString(), game('1. e4 e5'));
      GameStoreService.setTestInstance(
        GameStoreService(
          dbPathProvider: () async => '${root.path}/support/repaired.db',
        ),
      );
      final repaired = await store.load('import', 'alice');
      expect(repaired!.info.storageWarning, isNull);
      expect(
        (await GameStoreService.instance.open()).count(
          GameCollections.analysis(repaired.info.playerKey),
        ),
        1,
      );
    },
  );

  test(
    'legacy player migration retains originals and deletion stays deleted',
    () async {
      const info = AnalysisPlayerInfo(
        platform: 'import',
        username: 'alice_white_analysis',
      );
      final directory = Directory('${root.path}/analysis_games');
      await directory.create();
      final source = File('${directory.path}/${info.legacyPlayerKey}.pgn');
      await source.writeAsString(game('1. e4 e5'));
      await File(
        '${directory.path}/${info.legacyPlayerKey}.json',
      ).writeAsString(jsonEncode(info.toJson()));
      final store = PlayerCorpusStore();
      final migrated = await store.load(info.platform, info.username);
      expect(migrated, isNotNull);
      expect(await source.exists(), isTrue);
      await store.tombstone(info.platform, info.username);
      await store.tombstone(info.platform, info.username);
      expect(await store.load(info.platform, info.username), isNull);
      expect(await source.exists(), isTrue);
      expect(await File(migrated!.pgnPath).exists(), isTrue);
    },
  );
  test(
    'editing a published PGN invalidates engine caches in the same generation',
    () async {
      final service = AnalysisGamesService();
      await service.saveAnalysisGames(
        game('1. e4 e5'),
        platform: 'import',
        username: 'alice',
        maxGames: 100,
      );
      final fingerprint = await service.corpusFingerprint('import', 'alice');
      await service.saveEngineEvals('import', 'alice', [
        {'score': 10},
      ], expectedFingerprint: fingerprint);
      final path = await service.analysisPgnPath('import', 'alice');
      await File(path).writeAsString(game('1. d4 d5'));
      expect(await service.loadEngineEvals('import', 'alice'), isNull);
      await expectLater(
        service.saveEngineEvals('import', 'alice', [
          {'score': 20},
        ], expectedFingerprint: fingerprint),
        throwsStateError,
      );
      expect(await service.loadEngineEvals('import', 'alice'), isNull);
    },
  );

  test(
    'concurrent move-progress sessions reject stale changes to the same move',
    () async {
      final seed = RepertoireReviewService();
      final progress = RepertoireMoveProgress(
        repertoireId: 'rep',
        lineId: 'line',
        moveIndex: 0,
        correctStreak: 1,
        learned: false,
      );
      await seed.saveMoveProgress([progress]);
      final a = RepertoireReviewService();
      final b = RepertoireReviewService();
      final fromA = (await a.loadMoveProgress()).single;
      final fromB = (await b.loadMoveProgress()).single;
      await a.saveMoveProgress([
        fromA.copyWith(correctStreak: 2),
      ], repertoireId: 'rep');
      await expectLater(
        b.saveMoveProgress([
          fromB.copyWith(correctStreak: 3),
        ], repertoireId: 'rep'),
        throwsStateError,
      );
      expect((await seed.loadMoveProgress()).single.correctStreak, 2);
    },
  );
  test('library identity stays stable when tactics injects its GameId', () {
    final original = game('1. e4 e5', site: 'https://lichess.org/abcdefgh');
    final injected = original.replaceFirst(
      '[Result "*"]',
      '[Result "*"]\n[GameId "lichess_abcdefgh"]',
    );
    expect(
      GameRecord.parse(original).dedupKey,
      GameRecord.parse(injected).dedupKey,
    );
  });
}

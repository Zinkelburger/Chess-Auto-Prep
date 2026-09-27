import 'package:chess_auto_prep/infrastructure/documents/legacy_pgn_document_store.dart';
import 'package:chess_auto_prep/models/pgn_game_entry.dart';
import 'package:chess_auto_prep/app/runtime_settings.dart';
import 'package:chess_auto_prep/app/engine_runtime.dart';
import '../support/runtime_settings.dart';
import 'package:chess_auto_prep/app/viewer_dependencies.dart';
import '../support/fake_desktop_fullscreen_port.dart';
import 'package:chess_auto_prep/chess_core/pgn/pgn_collection_players.dart';
import 'package:chess_auto_prep/features/documents/models/viewer_perspective.dart';
import 'dart:async';

import 'package:chess_auto_prep/features/documents/repositories/pgn_collection_filter.dart';
import 'package:chess_auto_prep/infrastructure/documents/isolate_pgn_collection_filter.dart';

import 'package:chess_auto_prep/features/documents/repositories/pgn_collection_decoder.dart';
import 'package:chess_auto_prep/features/documents/models/viewer_collection_load.dart';
import 'package:chess_auto_prep/chess_core/pgn/pgn_collection.dart';
import 'package:chess_auto_prep/infrastructure/documents/storage_pgn_library_repository.dart';
import 'package:chess_auto_prep/infrastructure/documents/isolate_pgn_collection_decoder.dart';

import 'package:chess_auto_prep/infrastructure/documents/shared_preferences_viewer_repository.dart';
import 'package:chess_auto_prep/infrastructure/documents/storage_pgn_collection_repository.dart';

import 'package:dartchess/dartchess.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chess_auto_prep/features/documents/controllers/viewer_document_controller.dart';
import 'package:chess_auto_prep/models/pgn_filter_models.dart';
import 'package:chess_auto_prep/services/game_analysis_controller.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:chess_auto_prep/widgets/pgn_viewer_widget.dart';

class _GatedStorage extends IOStorageService {
  final reads = <String, Completer<String?>>{};

  @override
  Future<bool> fileExists(String path) async => !path.endsWith('.fenidx');

  @override
  Future<String?> readFile(String path) =>
      (reads[path] ??= Completer<String?>()).future;

  @override
  Future<({int size, DateTime modified})?> fileStat(String path) async =>
      (size: 1, modified: DateTime.fromMillisecondsSinceEpoch(1));
}

class _RecoveryStorage extends _GatedStorage {
  final retained = <String>[];
  @override
  Future<void> writeFile(
    String path,
    String content, {
    bool createOnly = false,
    String? expectedContent,
  }) async {
    expect(path, startsWith('recovery/'));
    expect(createOnly, isTrue);
    retained.add(content);
  }
}

/// Stub analysis controller: no isolates, no engine, no IO. Lets us exercise
/// `loadCurrentGame` (called by every navigation/slice method) deterministically.
class _FakeAnalysisController extends GameAnalysisController {
  _FakeAnalysisController()
    : super(pool: engines.pool, lifecycle: engines.lifecycle);
  @override
  Future<bool> tryLoadFromPgn(String pgnText) async => true;

  @override
  void cancel() {}
}

class _AbandonAnalysis extends _FakeAnalysisController {
  int cancellations = 0;
  int clears = 0;
  @override
  void cancel() => cancellations++;
  @override
  void clearEvals() => clears++;
}

class _GatedOpeningController extends ViewerDocumentController {
  _GatedOpeningController()
    : super(
        positionIndex: createViewerPositionIndex(),
        openings: createViewerOpenings(),
        solitaireRepository: createViewerSolitaire(),
        window: FakeDesktopFullscreenPort(),
        collectionDecoder: const IsolatePgnCollectionDecoder(),
        collectionFilter: const IsolatePgnCollectionFilter(),
        library: StoragePgnLibraryRepository(
          StorageFactory.instance,
          directory: () async => '/collections',
        ),
        preferences: SharedPreferencesViewerRepository(
          SharedPreferences.getInstance,
        ),
        collectionRepository: StoragePgnCollectionRepository(
          StorageFactory.instance,
          documents: LegacyPgnDocumentStore(StorageFactory.instance),
        ),
        pgnWidgetController: PgnViewerWidgetController(),
        analysisController: _FakeAnalysisController(),
      );

  final classificationStarted = Completer<void>();
  final classificationFinished = Completer<void>();

  @override
  Future<void> classifyOpenings() async {
    classificationStarted.complete();
    await classificationFinished.future;
  }
}

PgnGameEntry _game({String white = 'A', String black = 'B'}) {
  return PgnGameEntry(
    headers: {'White': white, 'Black': black},
    pgnText: '[White "$white"]\n[Black "$black"]\n\n1. e4 e5 *',
  );
}

class _ControlledDecoder implements PgnCollectionDecoder {
  final pending = Completer<DecodedPgnCollection>();
  @override
  Future<DecodedPgnCollection> decode(String content) => pending.future;
}

class _ControlledFilter implements PgnCollectionFilter {
  final pending = <Completer<List<int>>>[];
  @override
  Future<List<int>> match(
    SliceConfig config,
    List<GameRecord> games, {
    Map<String, List<int>>? fenIndex,
  }) {
    final result = Completer<List<int>>();
    pending.add(result);
    return result.future;
  }
}

class _GatedAnalysis extends _FakeAnalysisController {
  int enrichments = 0;
  @override
  Future<void> fillMissingBestLines(
    String pgnText, {
    void Function(String)? onAnnotatedMovetext,
  }) async {
    enrichments++;
  }

  final reads = <Completer<bool>>[];
  @override
  Future<bool> tryLoadFromPgn(String pgnText) {
    final result = Completer<bool>();
    reads.add(result);
    return result.future;
  }
}

class _FailingWindow extends FakeDesktopFullscreenPort {
  bool fail = true;
  @override
  Future<void> setFullScreen(bool value) async {
    if (fail) throw StateError('window failed');
    await super.setFullScreen(value);
  }
}

class _CursorHandle extends PgnViewerWidgetController {
  final jumps = <int>[];
  @override
  int get mainLineIndex => 7;
  @override
  void goToMainLineIndex(int index) => jumps.add(index);
}

ViewerDocumentController _makeController({
  FakeDesktopFullscreenPort? window,
  PgnViewerWidgetController? handle,
  void Function(void Function())? schedulePostFrame,
  GameAnalysisController? analysis,
  PgnCollectionDecoder decoder = const IsolatePgnCollectionDecoder(),
  PgnCollectionFilter matcher = const IsolatePgnCollectionFilter(),
}) {
  // A detached widget controller behaves as a no-op stub (its methods guard on
  // a null attached state), so it is safe to use without mounting a widget.
  return ViewerDocumentController(
    positionIndex: createViewerPositionIndex(),
    openings: createViewerOpenings(),
    solitaireRepository: createViewerSolitaire(),
    window: window ?? FakeDesktopFullscreenPort(),
    collectionDecoder: decoder,
    collectionFilter: matcher,
    library: StoragePgnLibraryRepository(
      StorageFactory.instance,
      directory: () async => '/collections',
    ),
    preferences: SharedPreferencesViewerRepository(
      SharedPreferences.getInstance,
    ),
    collectionRepository: StoragePgnCollectionRepository(
      StorageFactory.instance,
      documents: LegacyPgnDocumentStore(StorageFactory.instance),
    ),
    pgnWidgetController: handle ?? PgnViewerWidgetController(),
    schedulePostFrame: schedulePostFrame,
    analysisController: analysis ?? _FakeAnalysisController(),
  );
}

/// Populate the game list without going through `loadFile` (which needs storage
/// IO). Mirrors the post-load state the controller expects.
void _seed(ViewerDocumentController c, List<PgnGameEntry> games) {
  expect(c.adoptDecodedCollection(DecodedPgnCollection(games, '')), isNotNull);
}

RuntimeSettings? _engineFixtureSettings;
EngineRuntime get engines =>
    testEngines(_engineFixtureSettings ??= testRuntimeSettings());
void main() {
  setUp(() {
    _engineFixtureSettings = null;
    addTearDown(() => _engineFixtureSettings?.dispose());
  });
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    StorageFactory.instanceForTest = null;
  });

  test(
    'loading a setup game initializes its board and cannot reset a shown tree',
    () async {
      const fen = '4k3/8/8/4p3/8/8/8/4K3 b - - 0 17';
      final c = _makeController();
      addTearDown(c.dispose);
      _seed(c, [
        PgnGameEntry(
          headers: {'FEN': fen},
          pgnText: '[FEN "$fen"]\n\n17... e4 *',
        ),
      ]);
      await c.reading.loadCurrentGame();
      expect(
        c.reading.currentPosition.fen,
        Chess.fromSetup(Setup.parseFen(fen)).fen,
      );
      c.reading.toggleOpeningTree();
      await c.reading.tree.rebuild();
      c.reading.tree.onMoveSelected('e4');
      final treeFen = c.reading.currentPosition.fen;
      await c.reading.loadCurrentGame();
      expect(c.reading.currentPosition.fen, treeFen);
    },
  );

  test(
    'navigation restores the selected game, filter and board position',
    () async {
      final c = _makeController();
      addTearDown(c.dispose);
      final games = [_game(white: 'First'), _game(white: 'Second')];
      _seed(c, games);
      c.applySlice([1], const SliceConfig.empty());
      await c.reading.loadCurrentGame();
      const fen = '4k3/8/8/4p3/8/8/8/4K3 b - - 0 17';
      c.reading.pgnInitialFen = fen;
      final restore = c.captureNavigationContext();
      _seed(c, [_game(white: 'Other collection')]);
      c.reading.pgnInitialFen = null;

      await restore();

      expect(c.collection.games, games);
      expect(c.collection.visibleGames, [games[1]]);
      expect(c.collection.selectedIndex, 0);
      expect(c.filters.selection.active, isTrue);
      expect(
        c.reading.currentPosition.fen,
        Chess.fromSetup(Setup.parseFen(fen)).fen,
      );
    },
  );

  test(
    'restored cursor cannot move a newer selection in the same collection',
    () async {
      final frames = <void Function()>[];
      final handle = _CursorHandle();
      final c = _makeController(handle: handle, schedulePostFrame: frames.add);
      addTearDown(c.dispose);
      c.setAutoDetectOpenings(false);
      _seed(c, [_game(white: 'First'), _game(white: 'Second')]);
      final restore = c.captureNavigationContext();
      expect(await restore(), isTrue);
      expect(frames, isNotEmpty);
      await c.reading.selectGame(1);
      for (final callback in frames) {
        callback();
      }
      expect(c.collection.selectedIndex, 1);
      expect(handle.jumps, isEmpty);
    },
  );

  test(
    'reader opens and navigates while collection classification is pending',
    () async {
      final storage = _GatedStorage();
      StorageFactory.instanceForTest = storage;
      final c = _GatedOpeningController();
      addTearDown(c.dispose);
      final load = c.loadFile('/tmp/large.pgn', restoreSavedSlice: false);
      await Future<void>.delayed(Duration.zero);
      storage.reads['/tmp/large.pgn']!.complete(
        List.generate(
          1000,
          (i) =>
              '[Event "Game $i"]\n[White "A$i"]\n[Black "B$i"]\n\n1. e4 e5 *',
        ).join('\n\n'),
      );
      await load;
      await c.classificationStarted.future;
      expect(c.isLoading, isFalse);
      expect(c.isPreparingCollection, isTrue);
      expect(c.collection.games.length, 1000);
      c.reading.nextGame();
      expect(c.collection.selectedIndex, 1);
      c.closeFile();
      c.classificationFinished.complete();
      await Future<void>.delayed(Duration.zero);
      expect(c.collection.games, isEmpty);
      expect(c.isPreparingCollection, isFalse);
    },
  );

  test(
    'manual flip survives next and previous games and a pasted game',
    () async {
      final c = _makeController();
      addTearDown(c.dispose);
      _seed(c, [_game(), _game()]);
      c.presentation.toggleBoardFlipped();
      c.reading.nextGame();
      await c.reading.loadCurrentGame();
      expect(c.presentation.boardFlipped, isTrue);
      c.reading.prevGame();
      await c.reading.loadCurrentGame();
      expect(c.presentation.boardFlipped, isTrue);
      await c.loadPgnContent('[Event "Another"]\n\n1. d4 d5 *');
      expect(c.presentation.boardFlipped, isTrue);
      c.closeFile();
    },
  );

  group('filter request ownership', () {
    const first = SliceConfig(
      headerFilters: [
        HeaderFilterConfig(
          field: 'White',
          mode: MatchMode.exact,
          value: 'First',
        ),
      ],
    );
    const second = SliceConfig(
      headerFilters: [
        HeaderFilterConfig(
          field: 'White',
          mode: MatchMode.exact,
          value: 'Second',
        ),
      ],
    );
    test(
      'only the latest request changes the visible games and saved filter',
      () async {
        final matcher = _ControlledFilter();
        final c = _makeController(matcher: matcher);
        addTearDown(c.dispose);
        final games = [_game(white: 'First'), _game(white: 'Second')];
        _seed(c, games);
        c.filePath = '/tmp/filter-requests.pgn';
        final a = c.recomputeAndApplyConfig(first);
        final b = c.recomputeAndApplyConfig(second);
        matcher.pending[1].complete([1]);
        await b;
        matcher.pending[0].complete([0]);
        await a;
        expect(c.collection.visibleGames, [games[1]]);
        expect(c.isLoading, isFalse);
        expect(
          (await c.preferences.loadSlice(c.filePath!))!.toJsonString(),
          second.toJsonString(),
        );
      },
    );
    test(
      'filter failure preserves selection and same-selection retry clears its own error',
      () async {
        final matcher = _ControlledFilter();
        final c = _makeController(matcher: matcher);
        addTearDown(c.dispose);
        final games = [_game(), _game()];
        _seed(c, games);
        c.applySlice([0], first);
        final pending = c.recomputeAndApplyConfig(second);
        matcher.pending.single.completeError(StateError('worker failed'));
        await pending;
        expect(c.collection.visibleGames, [games[0]]);
        expect(c.isLoading, isFalse);
        expect(c.filters.error, isNotNull);
        expect(c.errorMessage, isNull);
        c.applySlice([0], first);
        expect(c.filters.error, isNull);
        expect(c.errorMessage, isNull);
        c.errorMessage = 'An unrelated failure';
        c.resetFilters();
        expect(c.errorMessage, 'An unrelated failure');
      },
    );
    test(
      'in-place edits recompute a pending filter against current headers',
      () async {
        final matcher = _ControlledFilter();
        final c = _makeController(matcher: matcher);
        addTearDown(c.dispose);
        final games = [_game(), _game()];
        _seed(c, games);
        c.editor.setAutoSave(false);
        c.editor.rememberPersistedGame(games[0]);
        final pending = c.recomputeAndApplyConfig(first);
        c.editor.setRating(4);
        matcher.pending.single.complete([1]);
        await Future<void>.delayed(Duration.zero);
        expect(matcher.pending, hasLength(2));
        matcher.pending.last.complete([0]);
        await pending;
        expect(c.collection.visibleGames, [games[0]]);
        expect(c.filters.selection.active, isTrue);
        expect(c.isLoading, isFalse);
        expect(games[0].studyRating, 4);
      },
    );
    test('a pending filter cannot release a newer collection load', () async {
      final matcher = _ControlledFilter();
      final decoder = _ControlledDecoder();
      final c = _makeController(matcher: matcher, decoder: decoder);
      addTearDown(c.dispose);
      _seed(c, [_game(), _game()]);
      final pending = c.recomputeAndApplyConfig(first);
      final loading = c.loadPgnContent('[Event "Replacement"]\n\n1. d4 *');
      matcher.pending.single.complete([1]);
      await pending;
      expect(c.isLoading, isTrue);
      decoder.pending.complete(
        DecodedPgnCollection(
          parseMultiGamePgn('[Event "Replacement"]\n\n1. d4 *'),
          '',
        ),
      );
      await loading;
      expect(c.filters.selection.active, isFalse);
      expect(c.collection.games.single.headers['Event'], 'Replacement');
    });
  });

  group('load ordering', () {
    for (final pasted in [false, true]) {
      test(
        'manual edits made during ${pasted ? 'paste decoding' : 'file loading'} keep the current document',
        () async {
          final storage = _GatedStorage();
          StorageFactory.instanceForTest = storage;
          final decoder = _ControlledDecoder();
          final c = _makeController(decoder: decoder);
          addTearDown(c.dispose);
          c.editor.setAutoSave(false);
          final game = _game();
          _seed(c, [game]);
          c.filePath = '/tmp/current.pgn';
          c.editor.rememberPersistedGame(game);
          const incoming = '[Event "Replacement"]\n\n1. d4 d5 *';
          final loading = pasted
              ? c.loadPgnContent(incoming)
              : c.loadFile('/tmp/new.pgn');
          await Future<void>.delayed(Duration.zero);
          c.persistMoveCommentsFor(game, '1. e4 { Keep my draft } e5 *');
          if (!pasted) storage.reads['/tmp/new.pgn']!.complete(incoming);
          decoder.pending.complete(
            DecodedPgnCollection(parseMultiGamePgn(incoming), ''),
          );
          await loading;
          expect(c.collection.games.single, same(game));
          expect(c.filePath, '/tmp/current.pgn');
          expect(game.pgnText, contains('Keep my draft'));
          expect(c.editor.hasUnsavedChanges, isTrue);
          expect(c.isLoading, isFalse);
          expect(c.editor.errorMessage, contains('Unsaved changes'));
        },
      );
    }

    test(
      'failed pasted decoding preserves the current document and releases loading',
      () async {
        final decoder = _ControlledDecoder();
        final c = _makeController(decoder: decoder);
        addTearDown(c.dispose);
        final game = _game();
        _seed(c, [game]);
        final loading = c.loadPgnContent('unreadable input');
        decoder.pending.completeError(const FormatException('bad document'));
        await loading;
        expect(c.collection.games.single, same(game));
        expect(c.isLoading, isFalse);
        expect(c.errorMessage, 'Could not parse the pasted PGN');
      },
    );

    test('a slower file read cannot replace the newest selection', () async {
      final storage = _GatedStorage();
      StorageFactory.instanceForTest = storage;
      final c = _makeController();
      addTearDown(c.dispose);

      final oldLoad = c.loadFile('/tmp/old.pgn');
      await Future<void>.delayed(Duration.zero);
      final newLoad = c.loadFile('/tmp/new.pgn');
      await Future<void>.delayed(Duration.zero);

      storage.reads['/tmp/new.pgn']!.complete(
        '[Event "New"]\n[White "New"]\n[Black "B"]\n\n1. d4 d5 *',
      );
      await newLoad;
      expect(c.filePath, '/tmp/new.pgn');
      expect(c.collection.games.single.headers['Event'], 'New');

      storage.reads['/tmp/old.pgn']!.complete(
        '[Event "Old"]\n[White "Old"]\n[Black "B"]\n\n1. e4 e5 *',
      );
      await oldLoad;

      expect(c.filePath, '/tmp/new.pgn');
      expect(
        c.collection.games.single.headers['Event'],
        'New',
        reason: 'late work must not land on the selected collection',
      );
    });

    test('closing the viewer invalidates a pending file read', () async {
      final storage = _GatedStorage();
      StorageFactory.instanceForTest = storage;
      final c = _makeController();
      addTearDown(c.dispose);

      final load = c.loadFile('/tmp/pending.pgn');
      await Future<void>.delayed(Duration.zero);
      c.closeFile();
      storage.reads['/tmp/pending.pgn']!.complete(
        '[Event "Late"]\n[White "A"]\n[Black "B"]\n\n1. e4 e5 *',
      );
      await load;

      expect(c.filePath, isNull);
      expect(c.collection.games, isEmpty);
      expect(c.isLoading, isFalse);
    });
  });

  for (final transition in [
    'file open',
    'pasted text',
    'decoded adoption',
    'workspace recovery',
    'navigation restoration',
    'close',
  ]) {
    test(
      '$transition abandons playback and analysis from the old collection',
      () async {
        final storage = _RecoveryStorage();
        StorageFactory.instanceForTest = storage;
        final decoder = _ControlledDecoder();
        final analysis = _AbandonAnalysis();
        final c = _makeController(decoder: decoder, analysis: analysis);
        addTearDown(c.dispose);
        _seed(c, [_game()]);
        c.setAutoDetectOpenings(false);
        final snapshot = c.captureWorkspace();
        final restoreNavigation = c.captureNavigationContext();
        final cancellations = analysis.cancellations;
        final clears = analysis.clears;
        c.reading.playback.start();
        expect(c.reading.playback.isPlaying, isTrue);
        final replacement = DecodedPgnCollection([_game(white: 'New')], '');
        switch (transition) {
          case 'file open':
            final operation = c.loadFile('/tmp/replacement.pgn');
            // Work stops at the request, before the slow file can finish.
            expect(c.reading.playback.isPlaying, isFalse);
            await Future<void>.delayed(Duration.zero);
            storage.reads['/tmp/replacement.pgn']!.complete(null);
            await operation;
          case 'pasted text':
            final operation = c.loadPgnContent('new games');
            expect(c.reading.playback.isPlaying, isFalse);
            decoder.pending.complete(replacement);
            await operation;
          case 'decoded adoption':
            c.adoptDecodedCollection(replacement);
          case 'workspace recovery':
            final operation = c.restoreWorkspace(snapshot);
            decoder.pending.complete(DecodedPgnCollection([_game()], ''));
            await operation;
            expect(storage.retained.single, contains('1. e4 e5'));
          case 'navigation restoration':
            await restoreNavigation();
          case 'close':
            c.closeFile();
        }
        expect(c.reading.playback.isPlaying, isFalse);
        expect(analysis.cancellations, greaterThan(cancellations));
        expect(analysis.clears, greaterThan(clears));
      },
    );
  }

  test(
    'close publishes completed teardown before a listener opens another collection',
    () {
      final c = _makeController();
      addTearDown(c.dispose);
      _seed(c, [_game(white: 'Departing')]);
      c.reading.playback.start();
      var reopened = false;
      c.changes.addListener(() {
        if (!c.reading.playback.isPlaying && !reopened) {
          reopened = true;
          c.adoptDecodedCollection(
            DecodedPgnCollection([_game(white: 'New')], ''),
          );
        }
      });
      c.closeFile();
      expect(reopened, isTrue);
      expect(c.collection.games.single.headers['White'], 'New');
    },
  );

  group('game navigation', () {
    test('goToGame moves to a valid index', () {
      final c = _makeController();
      _seed(c, [_game(), _game(), _game()]);

      c.reading.goToGame(2);
      expect(c.collection.selectedIndex, 2);
    });

    test('goToGame ignores out-of-range indices', () {
      final c = _makeController();
      _seed(c, [_game(), _game(), _game()]);

      c.reading.goToGame(1);
      c.reading.goToGame(-1);
      expect(
        c.collection.selectedIndex,
        1,
        reason: 'negative index is a no-op',
      );

      c.reading.goToGame(99);
      expect(
        c.collection.selectedIndex,
        1,
        reason: 'index >= length is a no-op',
      );
    });

    test('nextGame/prevGame clamp at the list bounds', () {
      final c = _makeController();
      _seed(c, [_game(), _game(), _game()]);

      c.reading.prevGame();
      expect(c.collection.selectedIndex, 0, reason: 'cannot go before first');

      c.reading.nextGame();
      c.reading.nextGame();
      c.reading.nextGame();
      expect(c.collection.selectedIndex, 2, reason: 'cannot go past last');

      c.reading.prevGame();
      expect(c.collection.selectedIndex, 1);
    });

    test('loadGameFromTree selects that game and leaves tree mode', () {
      final c = _makeController();
      _seed(c, [_game(), _game()]);

      c.reading.loadGameFromTree(1);

      expect(c.collection.selectedIndex, 1);
      expect(c.reading.tree.showOpeningTree, isFalse);
    });

    test(
      'nextGame clears a tree-landing FEN so the next game starts at move 1',
      () {
        final c = _makeController();
        _seed(c, [_game(), _game()]);
        c.reading.pgnInitialFen =
            'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';

        c.reading.nextGame();

        expect(c.reading.pgnInitialFen, isNull);
        expect(c.collection.selectedIndex, 1);
      },
    );

    test('navigation is a no-op when there are no games', () {
      final c = _makeController();
      expect(c.collection.visibleGames, isEmpty);

      c.reading.nextGame();
      c.reading.prevGame();
      c.reading.goToGame(0);
      expect(c.collection.selectedIndex, 0);
    });
  });

  group('collection player shortcuts', () {
    test(
      'detects arbitrary players on either side from the full collection',
      () {
        final c = _makeController();
        addTearDown(c.dispose);
        _seed(c, [
          _game(white: 'Polgar, Judit', black: 'Anand, Viswanathan'),
          _game(white: 'Kramnik, Vladimir', black: 'Polgar, Judit'),
        ]);
        expect(c.collection.collectionPlayer, 'Polgar, Judit');
        c.applySlice([1], const SliceConfig.empty());
        expect(c.collection.collectionPlayer, 'Polgar, Judit');
        _seed(c, [
          _game(white: 'my_username', black: 'Opponent A'),
          _game(white: 'Opponent B', black: 'my_username'),
        ]);
        expect(c.collection.collectionPlayer, 'my_username');
      },
    );

    test(
      'mixed and two-player collections have no single-player shortcuts',
      () {
        final c = _makeController();
        addTearDown(c.dispose);
        _seed(c, [
          _game(white: 'A', black: 'B'),
          _game(white: 'B', black: 'A'),
        ]);
        expect(c.collection.collectionPlayer, isNull);
        _seed(c, [
          for (var i = 0; i < 4; i++)
            _game(white: 'Early player', black: 'P$i'),
          for (var i = 4; i < 8; i++) _game(white: 'P$i', black: 'Q$i'),
        ]);
        expect(c.collection.collectionPlayer, isNull);
        _seed(c, [_game()]);
        expect(c.collection.collectionPlayer, isNull);
        _seed(c, []);
        expect(c.collection.collectionPlayer, isNull);
      },
    );

    test(
      'a clear majority tolerates incidental games and case differences',
      () {
        expect(
          detectSingleCollectionPlayer([
            for (var i = 0; i < 4; i++)
              _game(
                white: i.isEven ? 'Polgar, Judit' : 'POLGAR, JUDIT',
                black: 'P$i',
              ),
            _game(white: 'P4', black: 'P5'),
          ]),
          'Polgar, Judit',
        );
      },
    );
  });

  test('decoded adoption invalidates a pending pasted decode', () async {
    final decoder = _ControlledDecoder();
    final c = _makeController(decoder: decoder);
    addTearDown(c.dispose);
    final pending = c.loadPgnContent('[Event "Departed"]\n\n1. e4 *');
    final incoming = _game(white: 'Incoming');
    c.adoptDecodedCollection(DecodedPgnCollection([incoming], ''));
    decoder.pending.complete(
      DecodedPgnCollection([_game(white: 'Departed')], ''),
    );
    await pending;
    expect(c.collection.games, [incoming]);
    expect(c.isLoading, isFalse);
    expect(c.collection.selectedIndex, 0);
  });

  test(
    'reentrant same-row selection before analysis starts supersedes the earlier intent',
    () async {
      final analysis = _GatedAnalysis();
      final c = _makeController(analysis: analysis);
      addTearDown(c.dispose);
      _seed(c, [_game()]);
      var armed = true;
      Future<bool>? next;
      c.changes.addListener(() {
        if (!armed) return;
        armed = false;
        next = c.reading.selectGame(0);
      });
      expect(await c.reading.selectGame(0), isFalse);
      expect(analysis.reads, hasLength(1));
      analysis.reads.single.complete(false);
      expect(await next!, isTrue);
    },
  );

  test(
    'reentrant selection during orientation owns its own analysis acknowledgement',
    () async {
      final analysis = _GatedAnalysis();
      final c = _makeController(analysis: analysis);
      addTearDown(c.dispose);
      _seed(c, [_game()]);
      var notifications = 0;
      Future<bool>? reentrant;
      c.changes.addListener(() {
        notifications++;
        // The first notification publishes selection, the second orientation.
        if (notifications == 2) reentrant = c.reading.selectGame(0);
      });
      final first = c.reading.selectGame(0);
      expect(analysis.reads, hasLength(2));
      analysis.reads.last.complete(false);
      expect(await first, isFalse);
      analysis.reads.first.complete(false);
      expect(await reentrant!, isTrue);
    },
  );

  test(
    'disposal rejects pending selection without launching annotation work',
    () async {
      final analysis = _GatedAnalysis();
      final c = _makeController(analysis: analysis);
      _seed(c, [_game()]);
      final pending = c.reading.selectGame(0);
      c.dispose();
      analysis.reads.single.complete(true);
      expect(await pending, isFalse);
      expect(analysis.enrichments, 0);
      await c.reading.loadCurrentGame();
      expect(analysis.reads, hasLength(1));
    },
  );

  test(
    'a superseded awaited selection does not report readiness for the departed game',
    () async {
      final analysis = _GatedAnalysis();
      final c = _makeController(analysis: analysis);
      addTearDown(c.dispose);
      _seed(c, [_game(white: 'First'), _game(white: 'Second')]);
      final first = c.reading.selectGame(0);
      final second = c.reading.selectGame(1);
      analysis.reads.first.complete(false);
      expect(await first, isFalse);
      analysis.reads.last.complete(false);
      expect(await second, isTrue);
      expect(c.collection.selectedIndex, 1);
      expect(await c.reading.selectGame(8), isFalse);
    },
  );

  test(
    'decoded adoption protects membership and refuses replacement of manual edits',
    () {
      final c = _makeController();
      addTearDown(c.dispose);
      final games = [_game(white: 'First'), _game(white: 'Second')];
      _seed(c, games);
      final all = c.collection.games;
      final visible = c.collection.visibleGames;
      games.clear();
      expect(c.collection.games, hasLength(2));
      expect(() => c.collection.games.removeLast(), throwsUnsupportedError);
      expect(
        () => c.collection.visibleGames.sort((a, b) => 0),
        throwsUnsupportedError,
      );
      c.setSortMode(GameSortMode.fileOrder);
      expect(all, hasLength(2));
      expect(visible, hasLength(2));
      c.editor.setAutoSave(false);
      c.editor.setRating(5);
      expect(
        c.adoptDecodedCollection(
          DecodedPgnCollection([_game(white: 'New')], ''),
        ),
        isNull,
      );
      expect(c.collection.games, same(all));
      expect(c.editor.errorMessage, contains('Unsaved changes'));
    },
  );

  group('perspective', () {
    test(
      'window failure is retryable and cannot replace newer unrelated errors',
      () async {
        final window = _FailingWindow();
        final c = _makeController(window: window);
        addTearDown(c.dispose);
        await c.presentation.toggleFullScreen();
        expect(c.presentation.error, isA<StateError>());
        expect(c.errorMessage, isNull);
        c.errorMessage = 'Newer document failure';
        c.presentation.toggleBoardFlipped();
        expect(c.errorMessage, 'Newer document failure');
        window.fail = false;
        await c.presentation.toggleFullScreen();
        expect(c.presentation.isFullScreen, isTrue);
        expect(c.errorMessage, 'Newer document failure');
        window.fail = true;
        await c.presentation.exitFullScreen();
        expect(c.presentation.error, isA<StateError>());
        expect(c.errorMessage, 'Newer document failure');
        window.fail = false;
        await c.presentation.exitFullScreen();
        expect(c.presentation.error, isNull);
        expect(c.errorMessage, 'Newer document failure');
      },
    );

    test('setPerspective updates the field and notifies', () {
      final c = _makeController();
      var notifications = 0;
      c.changes.addListener(() => notifications++);

      c.setPerspective(const Perspective(mode: PerspectiveMode.black));
      expect(c.presentation.perspective.mode, PerspectiveMode.black);
      expect(notifications, greaterThan(0));
    });

    test('orientation follows perspective for the current game', () {
      final c = _makeController();
      _seed(c, [_game(white: 'hero', black: 'villain')]);
      c.editor.setAutoSave(false);
      addTearDown(c.dispose);

      c.setPerspective(const Perspective(mode: PerspectiveMode.white));
      expect(c.presentation.boardFlipped, isFalse);

      c.setPerspective(const Perspective(mode: PerspectiveMode.black));
      expect(c.presentation.boardFlipped, isTrue);

      c.setPerspective(
        const Perspective(mode: PerspectiveMode.player, playerName: 'villain'),
      );
      expect(
        c.presentation.boardFlipped,
        isTrue,
        reason: 'protagonist plays Black',
      );

      c.setPerspective(
        const Perspective(mode: PerspectiveMode.player, playerName: 'hero'),
      );
      expect(
        c.presentation.boardFlipped,
        isFalse,
        reason: 'protagonist plays White',
      );
    });
  });

  group('slicing', () {
    test(
      'filter apply and reset publish the selected sort order atomically',
      () {
        final c = _makeController();
        addTearDown(c.dispose);
        final games = [
          _game(white: 'Oldest'),
          _game(white: 'Newest'),
          _game(white: 'Middle'),
        ];
        for (var i = 0; i < games.length; i++) {
          games[i].headers['Date'] = [
            '2020.01.01',
            '2026.01.01',
            '2023.01.01',
          ][i];
        }
        _seed(c, games);
        c.setSortMode(GameSortMode.dateDesc);
        final published = <List<String>>[];
        c.changes.addListener(
          () => published.add(
            c.collection.visibleGames.map((g) => g.headers['Date']!).toList(),
          ),
        );
        c.applySlice([0, 2], const SliceConfig.empty());
        expect(c.collection.visibleGames, [games[2], games[0]]);
        c.resetFilters();
        expect(c.collection.visibleGames, [games[1], games[2], games[0]]);
        for (final dates in published) {
          expect(dates, List.of(dates)..sort((a, b) => b.compareTo(a)));
        }
      },
    );

    test('applySlice filters to the given indices and resets position', () {
      final c = _makeController();
      final games = List.generate(5, (i) => _game(white: 'P$i'));
      _seed(c, games);
      c.reading.goToGame(3);

      c.applySlice([1, 3], const SliceConfig.empty());

      expect(c.collection.visibleGames, hasLength(2));
      expect(c.collection.visibleGames[0], same(games[1]));
      expect(c.collection.visibleGames[1], same(games[3]));
      expect(c.filters.selection.active, isTrue);
      expect(
        c.collection.selectedIndex,
        0,
        reason: 'slice resets to first game',
      );
    });

    test('applySlice with identical indices+config is a no-op', () {
      final c = _makeController();
      _seed(c, [_game(), _game(), _game()]);

      c.applySlice([0, 1], const SliceConfig.empty());
      c.reading.goToGame(1);
      c.applySlice([0, 1], const SliceConfig.empty());

      expect(
        c.collection.selectedIndex,
        1,
        reason: 'repeat slice must not reset the cursor',
      );
    });

    test('resetFilters restores the full game list', () {
      final c = _makeController();
      final games = List.generate(4, (i) => _game(white: 'P$i'));
      _seed(c, games);
      c.applySlice([2], const SliceConfig.empty());
      expect(c.collection.visibleGames, hasLength(1));

      c.resetFilters();

      expect(c.collection.visibleGames, hasLength(4));
      expect(c.filters.selection.active, isFalse);
      expect(c.filters.selection.config.isEmpty, isTrue);
      expect(c.collection.selectedIndex, 0);
    });
  });

  group('closeFile', () {
    test('clears the collection back to the start-screen state', () {
      final c = _makeController();
      final games = List.generate(3, (i) => _game(white: 'P$i'));
      _seed(c, games);
      c.applySlice([1], const SliceConfig.empty());
      c.setPerspective(const Perspective(mode: PerspectiveMode.black));
      // Set last: a non-null path makes applySlice/setPerspective persist,
      // and this suite has no storage.
      c.filePath = '/tmp/games.pgn';
      c.errorMessage = 'stale';

      c.closeFile();

      expect(c.filePath, isNull);
      expect(c.collection.games, isEmpty);
      expect(c.collection.visibleGames, isEmpty);
      expect(c.filters.selection.active, isFalse);
      expect(c.filters.selection.config.isEmpty, isTrue);
      expect(c.collection.selectedIndex, 0);
      expect(c.errorMessage, isNull);
      expect(c.isLoading, isFalse);
      expect(c.reading.tree.showOpeningTree, isFalse);
      expect(c.presentation.perspective.mode, PerspectiveMode.white);
      expect(c.presentation.boardFlipped, isFalse);
    });

    test('closed collection membership remains protected', () {
      final c = _makeController();
      _seed(c, [_game(white: 'A'), _game(white: 'B')]);

      c.closeFile();

      expect(() => c.collection.games.add(_game()), throwsUnsupportedError);
      expect(
        () => c.collection.visibleGames.add(_game()),
        throwsUnsupportedError,
      );
      _seed(c, [_game()]);
      expect(c.collection.games, hasLength(1));
    });

    test('clears the protagonist detected from the closed collection', () {
      final c = _makeController();
      _seed(c, [
        _game(white: 'Carlsen', black: 'X'),
        _game(white: 'Carlsen', black: 'Y'),
      ]);

      c.closeFile();

      expect(c.collection.sliceProtagonist, isNull);
      expect(c.collection.protagonistFixedSide, isNull);
    });

    test('keeps the recent-files list — it is the way back in', () async {
      final c = _makeController();
      await c.libraryState.addToRecentFiles('/tmp/b.pgn');
      await c.libraryState.addToRecentFiles('/tmp/a.pgn');
      _seed(c, [_game()]);
      c.filePath = '/tmp/a.pgn';

      c.closeFile();

      expect(c.libraryState.recentFiles, ['/tmp/a.pgn', '/tmp/b.pgn']);
    });

    test('closed membership still supports a later sort through the owner', () {
      final c = _makeController();
      _seed(c, [_game(white: 'A'), _game(white: 'B')]);

      c.closeFile();

      // A const [] here would throw: applySortMode sorts filteredGames
      // in place for every mode but fileOrder.
      expect(() => c.setSortMode(GameSortMode.dateDesc), returnsNormally);
    });

    test('navigation after a close is a no-op', () {
      final c = _makeController();
      _seed(c, [_game(), _game()]);
      c.reading.goToGame(1);

      c.closeFile();
      c.reading.nextGame();
      c.reading.prevGame();

      expect(c.collection.selectedIndex, 0);
    });
  });
}

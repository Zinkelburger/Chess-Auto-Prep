library;

import 'package:chess_auto_prep/utils/atomic_file.dart';
import 'package:chess_auto_prep/infrastructure/documents/legacy_pgn_document_store.dart';

import 'package:chess_auto_prep/app/viewer_dependencies.dart';

/// What the viewer is allowed to do to a PGN file the reader owns.
///
/// A save patches the games it changed into the file as it currently stands
/// (`doPersistMetadata` → observed snapshot → patch → validated save). It used to
/// rewrite the whole file from the collection held in memory, and then
/// anything the load dropped, or any game a save re-serialized lossily, was
/// deleted from the reader's own file — by a star, a comment edit, or an
/// engine review they may not have asked for, since opening a reviewed game
/// fills in its missing engine lines and stores them.
///
/// Two such deletions have happened. Analysing a game rewrote it from
/// `moves.mainline()`, which cannot carry a variation or the game's opening
/// comment (fixed by routing every writer through `buildGameMovetext`). And a
/// `;`/`%` banner above the first game — what chessgames.com collection
/// downloads arrive with — is not a game, so it was not in the collection and
/// did not come back (fixed by `pgnCollectionPreamble`).
///
/// These tests are at the file level on purpose. The serializers are unit
/// tested elsewhere; what is asserted here is the property that matters to
/// the reader: **a save may add, and may change the game it was told to
/// change, but nothing else in the file may disappear.**

import 'package:chess_auto_prep/app/runtime_settings.dart';
import 'package:chess_auto_prep/app/engine_runtime.dart';
import '../../support/runtime_settings.dart';

import '../../support/fake_desktop_fullscreen_port.dart';

import 'dart:async';
import 'package:chess_auto_prep/features/documents/models/viewer_perspective.dart';

import 'package:chess_auto_prep/infrastructure/documents/isolate_pgn_collection_filter.dart';

import 'package:chess_auto_prep/infrastructure/documents/storage_pgn_library_repository.dart';
import 'package:chess_auto_prep/infrastructure/documents/isolate_pgn_collection_decoder.dart';

import 'package:chess_auto_prep/infrastructure/documents/shared_preferences_viewer_repository.dart';

import 'package:chess_auto_prep/infrastructure/documents/storage_pgn_collection_repository.dart';

import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chess_auto_prep/features/documents/controllers/viewer_document_controller.dart';
import 'package:chess_auto_prep/services/game_analysis_controller.dart';
import 'package:chess_auto_prep/chess_core/analysis/game_eval_annotations.dart';
import 'package:chess_auto_prep/chess_core/pgn/pgn_text.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:chess_auto_prep/services/storage/storage_service.dart';
import 'package:chess_auto_prep/widgets/pgn_viewer_widget.dart';

/// In-memory storage. `writeFile` replaces the whole file, exactly as the
/// atomic writer behind the real one does, and every write moves the file's
/// mtime — which is what tells the viewer its copy is no longer the newest.
class _MemoryStorage implements StorageService {
  final Map<String, String> files = {};
  final Map<String, DateTime> modified = {};
  Completer<void>? writeGate;

  var _clock = DateTime(2026, 9, 4, 12);

  /// Write as something *else* would: the app's review runner patching this
  /// file in place, or the reader editing it in another program.
  void writeBehindOurBack(String path, String content) {
    files[path] = content;
    _clock = _clock.add(const Duration(seconds: 1));
    modified[path] = _clock;
  }

  @override
  Future<bool> fileExists(String path) async => files.containsKey(path);

  @override
  Future<String?> readFile(String path) async => files[path];

  @override
  Future<void> writeFile(
    String path,
    String content, {
    bool createOnly = false,
    String? expectedContent,
  }) async {
    await writeGate?.future;
    if ((createOnly && files.containsKey(path)) ||
        (expectedContent != null && files[path] != expectedContent)) {
      throw AtomicWriteConflict(path);
    }
    writeBehindOurBack(path, content);
  }

  /// Storage read-modify-write for callers outside the document store.
  @override
  Future<String> updateFile(
    String path,
    FutureOr<String> Function(String?) update,
  ) async {
    await writeGate?.future;
    final next = await update(files[path]);
    writeBehindOurBack(path, next);
    return next;
  }

  @override
  Future<({int size, DateTime modified})?> fileStat(String path) async {
    final content = files[path];
    if (content == null) return null;
    return (size: content.length, modified: modified[path] ?? _clock);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not used here');
}

/// No engine, no isolates: `loadCurrentGame` runs on every navigation.
class _FakeAnalysisController extends GameAnalysisController {
  _FakeAnalysisController()
    : super(pool: engines.pool, lifecycle: engines.lifecycle);
  @override
  Future<bool> tryLoadFromPgn(String pgnText) async => true;

  @override
  void cancel() {}
}

const _path = '/library/important.pgn';

/// A file worth caring about: a banner the reader wrote, a first game with an
/// opening comment, a NAG and two sidelines (one of them nested), and two more
/// games that nothing in these tests ever asks to change.
const _bannerLine = '; My games, annotated by hand. Do not lose this.';

const _gameOne =
    '[Event "Club championship"]\n'
    '[White "me"]\n'
    '[Black "opp"]\n'
    '[Result "1-0"]\n'
    '\n'
    '{ the whole point of the file [%clk 0:05:00] } '
    '1. e4 { my note } (1. d4 d5 (1... Nf6 2. c4) 2. c4) '
    'e5 \$2 2. Nf3 Nc6 1-0\n';

const _gameTwo =
    '[Event "Club championship"]\n'
    '[White "opp"]\n'
    '[Black "me"]\n'
    '[Result "0-1"]\n'
    '\n'
    '1. d4 { theirs, untouched } d5 (1... Nf6) 2. c4 0-1\n';

const _gameThree =
    '[Event "Simul"]\n'
    '[White "me"]\n'
    '[Black "master"]\n'
    '[Result "*"]\n'
    '\n'
    '1. c4 e5 (1... c5 2. g3) *\n';

String _fileText() =>
    '$_bannerLine\n\n${_gameOne.trim()}\n\n'
    '${_gameTwo.trim()}\n\n${_gameThree.trim()}\n';

/// Every move node in a tree, mainline and variations alike.
int _nodeCount(PgnNode<PgnNodeData> root) {
  var count = 0;
  final stack = [root];
  while (stack.isNotEmpty) {
    final node = stack.removeLast();
    count += node.children.length;
    stack.addAll(node.children);
  }
  return count;
}

/// The NAGs on each mainline move, in order.
List<List<int>> _nagsOf(PgnGame<PgnNodeData> game) => [
  for (final n in game.moves.mainline()) n.nags ?? const <int>[],
];

/// The comments and machine tokens sitting on every node of a game.
List<String> _allComments(PgnGame<PgnNodeData> game) {
  final out = <String>[...game.comments];
  final stack = [game.moves];
  while (stack.isNotEmpty) {
    final node = stack.removeLast();
    for (final child in node.children) {
      out.addAll(child.data.comments ?? const []);
      stack.add(child);
    }
  }
  return out..sort();
}

Future<ViewerDocumentController> _openTheFile(_MemoryStorage storage) async {
  storage.writeBehindOurBack(_path, _fileText());
  final controller = ViewerDocumentController(
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
  await controller.loadFile(_path, restoreSavedSlice: false);
  return controller;
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

  late _MemoryStorage storage;

  setUp(() {
    // File-preservation tests own their edits; opening classification has its
    // own tests and must not race these snapshots with extra header writes.
    SharedPreferences.setMockInitialValues({
      'pgn_viewer.auto_detect_openings': false,
    });
    storage = _MemoryStorage();
    StorageFactory.instanceForTest = storage;
  });

  tearDown(() => StorageFactory.instanceForTest = null);

  test('navigation keeps drill-only notes out of later file saves', () async {
    final c = await _openTheFile(storage);
    addTearDown(c.dispose);
    final game = c.collection.games.first;
    c.persistMoveCommentsFor(
      game,
      '1. e4 {drill-only} e5 *',
      writeToFile: false,
    );
    final back = c.captureNavigationContext();
    await c.loadPgnContent('[Event "Elsewhere"]\n\n1. d4 *');
    expect(await back(), isTrue);
    expect(game.pgnText, contains('drill-only'));
    expect(c.editor.snapshotForSave()[game], isNot(contains('drill-only')));
    c.setPerspective(const Perspective(mode: PerspectiveMode.black));
    await c.editor.flushPendingMetadata();
    expect(storage.files[_path], isNot(contains('drill-only')));
    expect(storage.files[_path], contains('[StudyPerspective "black"]'));
  });

  test(
    'navigation return retains an outgoing save conflict and original bytes',
    () async {
      final c = await _openTheFile(storage);
      addTearDown(c.dispose);
      final game = c.collection.games.first;
      final original = game.pgnText;
      final gate = Completer<void>();
      storage.writeGate = gate;
      c.persistMoveCommentsFor(game, '1. e4 {my draft} e5 *');
      final saving = c.editor.doPersistMetadata();
      final back = c.captureNavigationContext();
      await c.loadPgnContent('[Event "Elsewhere"]\n\n1. d4 *');
      expect(await back(), isTrue);
      storage.writeBehindOurBack(
        _path,
        '[Event "External replacement"]\n\n1. c4 *',
      );
      gate.complete();
      await saving;
      await c.editor.flushPendingMetadata();
      expect(c.editor.hasUnsavedChanges, isTrue);
      expect(c.editor.needsSaveRecovery, isTrue);
      expect(c.captureWorkspace().persistedGames.first, original);
      expect(c.editor.canReplaceCollection(), isFalse);
      expect(storage.files[_path], contains('External replacement'));
      expect(game.pgnText, contains('my draft'));
    },
  );

  test('manual edits stay off disk across games and save explicitly', () async {
    final c = await _openTheFile(storage);
    addTearDown(c.dispose);
    c.editor.setAutoSave(false);
    final original = storage.files[_path];
    final untouched = c.collection.games[1].pgnText;
    c.persistMoveCommentsFor(
      c.collection.games.first,
      '1. e4 { manual note } (1. d4 d5) e5 1-0',
    );
    c.reading.goToGame(1);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await c.editor.flushPendingMetadata();
    expect(storage.files[_path], original);
    expect(c.editor.hasUnsavedChanges, isTrue);
    c.closeFile();
    expect(c.collection.games, hasLength(3));
    await c.loadPgnContent('[Result "*"]\n\n1. a3 *');
    expect(c.collection.games, hasLength(3));
    expect(await c.editor.saveChanges(), isTrue);
    expect(c.editor.hasUnsavedChanges, isFalse);
    expect(c.editor.state.busy, isFalse);
    expect(storage.files[_path], contains('manual note'));
    expect(storage.files[_path], contains(untouched.trim()));
    c.closeFile();
    expect(c.collection.games, isEmpty);
  });

  test('enabling autosave saves pending manual edits', () async {
    final c = await _openTheFile(storage);
    addTearDown(c.dispose);
    c.editor.setAutoSave(false);
    c.persistMoveCommentsFor(
      c.collection.games.first,
      '1. e4 { pending } e5 1-0',
    );
    c.editor.setAutoSave(true);
    await c.editor.flushPendingMetadata();
    expect(storage.files[_path], contains('pending'));
    expect(c.editor.hasUnsavedChanges, isFalse);
  });

  test('discard restores the original PGN without writing it', () async {
    final c = await _openTheFile(storage);
    addTearDown(c.dispose);
    c.editor.setAutoSave(false);
    final original = c.collection.games.first.pgnText;
    c.persistMoveCommentsFor(c.collection.games.first, '1. a3 1-0');
    c.editor.discardChanges();
    expect(c.editor.hasUnsavedChanges, isFalse);
    expect(c.collection.games.first.pgnText, original);
  });

  test('edits made during a write stay unsaved until the next Save', () async {
    final c = await _openTheFile(storage);
    addTearDown(c.dispose);
    c.editor.setAutoSave(false);
    c.persistMoveCommentsFor(
      c.collection.games.first,
      '1. e4 { first edit } e5 1-0',
    );
    storage.writeGate = Completer<void>();
    final saving = c.editor.saveChanges();
    expect(c.editor.state.busy, isTrue);
    c.persistMoveCommentsFor(
      c.collection.games.first,
      '1. e4 { second edit } e5 1-0',
    );
    storage.writeGate!.complete();
    expect(await saving, isFalse);
    expect(c.editor.hasUnsavedChanges, isTrue);
    expect(storage.files[_path], contains('first edit'));
    expect(storage.files[_path], isNot(contains('second edit')));
    expect(await c.editor.saveChanges(), isTrue);
    expect(storage.files[_path], contains('second edit'));
  });

  test(
    'Save As snapshot retains notes and ratings and becomes the backing file',
    () async {
      final c = await _openTheFile(storage);
      addTearDown(c.dispose);
      c.closeFile();
      await c.loadPgnContent(_gameOne);
      c.editor.setAutoSave(false);
      c.persistMoveCommentsFor(
        c.collection.games.first,
        '1. e4 { pasted note } e5 1-0',
      );
      c.editor.setRating(3);
      final snapshot = c.editor.snapshotForSave();
      expect(snapshot.values.single, contains('pasted note'));
      expect(snapshot.values.single, contains('[StudyRating "3"]'));
      await c.editor.saveCopy('/library/new.pgn');
      expect(c.editor.hasUnsavedChanges, isFalse);
      await c.reading.saveSession();
      expect(
        (await SharedPreferences.getInstance()).getString(
          'pgn_viewer.last_file',
        ),
        '/library/new.pgn',
      );
      expect(c.loadedFileModified, isNull);
      c.persistMoveCommentsFor(
        c.collection.games.first,
        '1. e4 { later edit } e5 1-0',
      );
      expect(await c.editor.saveChanges(), isTrue);
      expect(storage.files['/library/new.pgn'], contains('later edit'));
    },
  );

  test('the file opens as three games, banner excluded', () async {
    final c = await _openTheFile(storage);
    addTearDown(c.dispose);

    expect(c.collection.games.length, 3);
    expect(c.collectionPreamble, _bannerLine);
  });

  test('an engine review leaves every other game byte-identical', () async {
    final c = await _openTheFile(storage);
    addTearDown(c.dispose);

    final untouched = [
      c.collection.games[1].pgnText,
      c.collection.games[2].pgnText,
    ];

    // What the viewer stores when a review — or merely opening a reviewed
    // game, which fills in the lines the pass did not write — produces engine
    // lines for the game on screen.
    final annotated = injectBestLines(c.collection.games.first.pgnText, {
      1: const ['e4', 'e5', 'Nf3'],
    });
    expect(annotated, isNotNull, reason: 'the writer had something to write');
    c.editor.persistMoveComments(annotated!);
    await c.editor.flushPendingMetadata();

    final written = storage.files[_path]!;
    final games = splitPgnIntoGames(written);
    expect(games.length, 3, reason: 'no game was dropped');
    expect(games[1].trim(), untouched[0].trim());
    expect(games[2].trim(), untouched[1].trim());
  });

  test('an engine review keeps the reviewed game whole', () async {
    final c = await _openTheFile(storage);
    addTearDown(c.dispose);

    final before = PgnGame.parsePgn(c.collection.games.first.pgnText);
    final annotated = injectBestLines(c.collection.games.first.pgnText, {
      1: const ['e4', 'e5', 'Nf3'],
    })!;
    c.editor.persistMoveComments(annotated);
    await c.editor.flushPendingMetadata();

    final after = PgnGame.parsePgn(splitPgnIntoGames(storage.files[_path]!)[0]);

    expect(
      _nodeCount(after.moves),
      _nodeCount(before.moves),
      reason: 'a sideline (or a sideline of a sideline) was deleted',
    );
    expect(
      after.comments,
      before.comments,
      reason: "the game's own opening comment was deleted",
    );
    expect(_nagsOf(after), _nagsOf(before), reason: 'a NAG went missing');
    expect(
      _nagsOf(before).any((nags) => nags.isNotEmpty),
      isTrue,
      reason: 'the fixture has to carry a NAG for that to mean anything',
    );
    // Everything that was there is still there — a review *adds* to a comment
    // (the `[%pv]` lands beside the prose), so each one has to still be found
    // inside the comment that replaced it rather than equal to it.
    for (final comment in _allComments(before)) {
      expect(
        _allComments(after).any((a) => a.contains(comment)),
        isTrue,
        reason: 'the file lost the comment "$comment"',
      );
    }
    expect(
      after.moves.mainline().first.comments!.join(' '),
      contains('[%pv e4,e5,Nf3]'),
    );
    expect(after.headers['White'], 'me', reason: 'headers survived the splice');
  });

  test('starring a game does not delete the banner above it', () async {
    final c = await _openTheFile(storage);
    addTearDown(c.dispose);

    c.editor.setRating(3);
    await c.editor.flushPendingMetadata();

    final written = storage.files[_path]!;
    expect(written.trimLeft(), startsWith(_bannerLine));
    expect(splitPgnIntoGames(written).length, 3);
    expect(written, contains('[StudyRating "3"]'));
  });

  test('a save is idempotent: saving twice changes nothing more', () async {
    final c = await _openTheFile(storage);
    addTearDown(c.dispose);

    c.editor.setRating(3);
    await c.editor.flushPendingMetadata();
    final once = storage.files[_path]!;

    c.editor.setRating(3);
    await c.editor.flushPendingMetadata();
    expect(storage.files[_path], once);
  });

  test('reopening the file gives back what was saved', () async {
    final c = await _openTheFile(storage);
    addTearDown(c.dispose);
    c.editor.persistMoveComments(
      injectBestLines(c.collection.games.first.pgnText, {
        1: const ['e4', 'e5', 'Nf3'],
      })!,
    );
    await c.editor.flushPendingMetadata();

    final reopened = ViewerDocumentController(
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
    addTearDown(reopened.dispose);
    await reopened.loadFile(_path, restoreSavedSlice: false);

    expect(reopened.collection.games.length, 3);
    expect(reopened.collectionPreamble, _bannerLine);
    expect(
      _nodeCount(
        PgnGame.parsePgn(reopened.collection.games.first.pgnText).moves,
      ),
      _nodeCount(PgnGame.parsePgn(_gameOne).moves),
    );
  });

  // ── The file moving under an open viewer ──────────────────────────────
  //
  // A save rewrites the whole file from memory, which is right only while
  // that memory is the newest copy. The app itself breaks that: the home
  // review runner patches this file in place while the viewer holds it open.

  test('a save keeps what something else wrote to another game', () async {
    final c = await _openTheFile(storage);
    addTearDown(c.dispose);

    // Something else annotates game two — the review runner's own write.
    final patched = storage.files[_path]!.replaceFirst(
      '1. d4 { theirs, untouched } d5',
      '1. d4 { theirs, untouched } { [%eval 0.21,18] } d5',
    );
    storage.writeBehindOurBack(_path, patched);

    // Now the reader stars game one, which rewrites the whole file.
    c.editor.setRating(4);
    await c.editor.flushPendingMetadata();

    final written = storage.files[_path]!;
    expect(
      written,
      contains('[%eval 0.21,18]'),
      reason: "the other writer's work was reverted by our save",
    );
    expect(written, contains('[StudyRating "4"]'), reason: 'our star landed');
    expect(splitPgnIntoGames(written).length, 3);
  });

  test('a game added to the file by something else is not deleted', () async {
    final c = await _openTheFile(storage);
    addTearDown(c.dispose);

    const extra =
        '[Event "Added elsewhere"]\n'
        '[White "me"]\n'
        '[Black "someone new"]\n'
        '[Result "*"]\n'
        '\n'
        '1. Nf3 d5 *\n';
    storage.writeBehindOurBack(
      _path,
      '${storage.files[_path]!.trimRight()}\n\n$extra',
    );

    c.editor.setRating(2);
    await c.editor.flushPendingMetadata();

    final written = storage.files[_path]!;
    expect(
      splitPgnIntoGames(written).length,
      4,
      reason: 'the new game is gone',
    );
    expect(written, contains('someone new'));
    expect(written, contains('[StudyRating "2"]'));
    expect(written.trimLeft(), startsWith(_bannerLine));
  });

  test('a file replaced by something unrecognisable is left alone', () async {
    final c = await _openTheFile(storage);
    addTearDown(c.dispose);

    // No games at all: whatever this is, it is not the collection we loaded,
    // and writing our copy over it would destroy it.
    storage.writeBehindOurBack(_path, '; someone emptied this file\n');

    c.editor.setRating(5);
    await c.editor.flushPendingMetadata();

    expect(storage.files[_path], '; someone emptied this file\n');
    expect(c.editor.hasUnsavedChanges, isTrue);
    expect(c.editor.state.busy, isFalse);
    expect(c.editor.errorMessage, contains('recovery'));
  });

  test('an unchanged file still gets the plain whole-file write', () async {
    final c = await _openTheFile(storage);
    addTearDown(c.dispose);

    c.editor.setRating(1);
    await c.editor.flushPendingMetadata();

    final written = storage.files[_path]!;
    expect(splitPgnIntoGames(written).length, 3);
    expect(written, contains('[StudyRating "1"]'));
    expect(written.trimLeft(), startsWith(_bannerLine));
  });
}

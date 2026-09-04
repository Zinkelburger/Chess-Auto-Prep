/// What the viewer is allowed to do to a PGN file the reader owns.
///
/// The viewer does not patch a file in place: every save rewrites the whole
/// thing from the collection it holds in memory (`doPersistMetadata`). So
/// anything the load dropped, or any game a save re-serialized lossily, is
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
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chess_auto_prep/core/pgn_viewer_controller.dart';
import 'package:chess_auto_prep/services/game_analysis_controller.dart';
import 'package:chess_auto_prep/services/pgn_parsing_service.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:chess_auto_prep/services/storage/storage_service.dart';
import 'package:chess_auto_prep/widgets/pgn_viewer_widget.dart';

/// In-memory storage. `writeFile` replaces the whole file, exactly as the
/// atomic writer behind the real one does.
class _MemoryStorage implements StorageService {
  final Map<String, String> files = {};

  @override
  Future<bool> fileExists(String path) async => files.containsKey(path);

  @override
  Future<String?> readFile(String path) async => files[path];

  @override
  Future<void> writeFile(String path, String content) async {
    files[path] = content;
  }

  @override
  Future<({int size, DateTime modified})?> fileStat(String path) async {
    final content = files[path];
    if (content == null) return null;
    return (size: content.length, modified: DateTime(2026, 9, 4));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not used here');
}

/// No engine, no isolates: `loadCurrentGame` runs on every navigation.
class _FakeAnalysisController extends GameAnalysisController {
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

Future<PgnViewerController> _openTheFile(_MemoryStorage storage) async {
  storage.files[_path] = _fileText();
  final controller = PgnViewerController(
    pgnWidgetController: PgnViewerWidgetController(),
    analysisController: _FakeAnalysisController(),
  );
  await controller.loadFile(_path, restoreSavedSlice: false);
  return controller;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MemoryStorage storage;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    storage = _MemoryStorage();
    StorageFactory.instanceForTest = storage;
  });

  tearDown(() => StorageFactory.instanceForTest = null);

  test('the file opens as three games, banner excluded', () async {
    final c = await _openTheFile(storage);
    addTearDown(c.dispose);

    expect(c.allGames.length, 3);
    expect(c.collectionPreamble, _bannerLine);
  });

  test('an engine review leaves every other game byte-identical', () async {
    final c = await _openTheFile(storage);
    addTearDown(c.dispose);

    final untouched = [c.allGames[1].pgnText, c.allGames[2].pgnText];

    // What the viewer stores when a review — or merely opening a reviewed
    // game, which fills in the lines the pass did not write — produces engine
    // lines for the game on screen.
    final annotated = injectBestLines(c.allGames.first.pgnText, {
      1: const ['e4', 'e5', 'Nf3'],
    });
    expect(annotated, isNotNull, reason: 'the writer had something to write');
    c.persistMoveComments(annotated!);
    await c.flushPendingMetadata();

    final written = storage.files[_path]!;
    final games = splitPgnIntoGames(written);
    expect(games.length, 3, reason: 'no game was dropped');
    expect(games[1].trim(), untouched[0].trim());
    expect(games[2].trim(), untouched[1].trim());
  });

  test('an engine review keeps the reviewed game whole', () async {
    final c = await _openTheFile(storage);
    addTearDown(c.dispose);

    final before = PgnGame.parsePgn(c.allGames.first.pgnText);
    final annotated = injectBestLines(c.allGames.first.pgnText, {
      1: const ['e4', 'e5', 'Nf3'],
    })!;
    c.persistMoveComments(annotated);
    await c.flushPendingMetadata();

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

    c.setRating(3);
    await c.flushPendingMetadata();

    final written = storage.files[_path]!;
    expect(written.trimLeft(), startsWith(_bannerLine));
    expect(splitPgnIntoGames(written).length, 3);
    expect(written, contains('[StudyRating "3"]'));
  });

  test('a save is idempotent: saving twice changes nothing more', () async {
    final c = await _openTheFile(storage);
    addTearDown(c.dispose);

    c.setRating(3);
    await c.flushPendingMetadata();
    final once = storage.files[_path]!;

    c.setRating(3);
    await c.flushPendingMetadata();
    expect(storage.files[_path], once);
  });

  test('reopening the file gives back what was saved', () async {
    final c = await _openTheFile(storage);
    addTearDown(c.dispose);
    c.persistMoveComments(
      injectBestLines(c.allGames.first.pgnText, {
        1: const ['e4', 'e5', 'Nf3'],
      })!,
    );
    await c.flushPendingMetadata();

    final reopened = PgnViewerController(
      pgnWidgetController: PgnViewerWidgetController(),
      analysisController: _FakeAnalysisController(),
    );
    addTearDown(reopened.dispose);
    await reopened.loadFile(_path, restoreSavedSlice: false);

    expect(reopened.allGames.length, 3);
    expect(reopened.collectionPreamble, _bannerLine);
    expect(
      _nodeCount(PgnGame.parsePgn(reopened.allGames.first.pgnText).moves),
      _nodeCount(PgnGame.parsePgn(_gameOne).moves),
    );
  });
}

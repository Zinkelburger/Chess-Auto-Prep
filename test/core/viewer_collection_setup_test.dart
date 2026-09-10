import 'package:chess_auto_prep/core/pgn/viewer_opening_tree.dart';
import 'package:chess_auto_prep/core/pgn/viewer_game_model.dart';
import 'package:chess_auto_prep/models/pgn_game_entry.dart';
import 'package:chess_auto_prep/services/opening_tree_builder.dart';
import 'package:chess_auto_prep/utils/fen_utils.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

const setupFen = '4k3/8/8/4p3/8/8/8/4K3 b - - 0 17';
const chapter = '[FEN "$setupFen"]\n[Result "*"]\n\n17... e4 18. Kd2 Kd7 *';

PgnGameEntry entry(String text) =>
    PgnGameEntry(headers: PgnGame.parsePgn(text).headers, pgnText: text);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('reader uses the same FEN setup without a SetUp tag', () {
    final model = ViewerGameModel()..load(PgnGame.parsePgn(chapter));
    expect(normalizeFen(model.startPosition.fen), normalizeFen(setupFen));
    expect(model.mainline.reachablePlies, 3);
  });

  for (final variations in [false, true]) {
    test(
      'null moves keep a replayable collection path (RAVs: $variations)',
      () async {
        final tree = await OpeningTreeBuilder.buildTree(
          pgnList: ['1. e4 Z0 2. d4 *'],
          username: '',
          userIsWhite: null,
          strictPlayerMatching: false,
          preserveSetupRoots: true,
          includeVariations: variations,
        );
        expect(tree.makeMove('e4'), isTrue);
        final beforePass = tree.currentFen;
        expect(tree.makeMove('Z0'), isTrue);
        final afterPass = tree.currentFen;
        expect(tree.makeMove('d4'), isTrue);
        expect(tree.goBack(), isTrue);
        expect(normalizeFen(tree.currentFen), normalizeFen(afterPass));
        expect(tree.goBack(), isTrue);
        expect(normalizeFen(tree.currentFen), normalizeFen(beforePass));
      },
    );
  }

  test('setup roots survive isolate transfer and a colliding SAN', () async {
    final tree = await OpeningTreeBuilder.buildTree(
      pgnList: ['1. e4 e5 *', chapter],
      username: '',
      userIsWhite: null,
      strictPlayerMatching: false,
      preserveSetupRoots: true,
    );
    expect(tree.totalGames, 2);
    expect(tree.root.gamesPlayed, 1);
    expect(tree.navigateToFen(setupFen), isTrue);
    expect(tree.currentMovePath, isEmpty);
    expect(tree.makeMove('e4'), isTrue);
    expect(tree.currentMovePathString, '17...e4');
    final afterPawn = tree.currentFen;
    expect(tree.makeMove('Kd2'), isTrue);
    expect(tree.goBack(), isTrue);
    expect(normalizeFen(tree.currentFen), normalizeFen(afterPawn));
    expect(tree.goBack(), isTrue);
    expect(normalizeFen(tree.currentFen), normalizeFen(setupFen));
    expect(tree.goBack(), isFalse);
    tree.reset();
    expect(tree.makeMove('e4'), isTrue);
    expect(tree.currentFen, isNot(afterPawn));
    expect(tree.root.children['e4']!.gamesPlayed, 1);
  });

  test(
    'setup chapter navigation, return, rebuild, and sorted matches',
    () async {
      var games = [entry('1. e4 e5 *'), entry(chapter)];
      Position board = Chess.fromSetup(Setup.parseFen(setupFen));
      final viewer = ViewerOpeningTree(
        isActive: () => true,
        onChanged: () {},
        filteredGames: () => games,
        allGames: () => games,
        fenIndex: () => null,
        currentFen: () => board.fen,
        gameStartFen: () => setupFen,
        applyPosition: (position) => board = position,
      );
      await viewer.enter();
      expect(normalizeFen(board.fen), normalizeFen(setupFen));
      expect(viewer.gamesAtTreePosition(), [1]);
      viewer.onMoveSelected('e4');
      expect(viewer.recentMoveSquares, {'e5', 'e4'});
      final pawnFen = board.fen;
      viewer.snapshotCursor(leavingForGame: true);
      viewer.hide();
      board = Chess.initial;
      await viewer.enter();
      expect(normalizeFen(board.fen), normalizeFen(pawnFen));
      viewer.onMoveSelected('Kd2');
      final kingFen = board.fen;
      await viewer.rebuild();
      expect(normalizeFen(board.fen), normalizeFen(kingFen));
      games = games.reversed.toList();
      viewer.clearCache();
      expect(viewer.gamesAtTreePosition(), [0]);
      games = games.reversed.toList();
      viewer.clearCache();
      viewer.setIncludeVariations(true);
      while (viewer.buildingTree) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(normalizeFen(board.fen), normalizeFen(kingFen));
      expect(viewer.gamesAtTreePosition(), [1]);
      viewer.goBack();
      expect(normalizeFen(board.fen), normalizeFen(pawnFen));
      games = games.reversed.toList();
      viewer.clearCache();
      expect(viewer.gamesAtTreePosition(), [0]);
      viewer.resetToStart();
      expect(normalizeFen(board.fen), normalizeFen(setupFen));
      viewer.goBack();
      expect(normalizeFen(board.fen), normalizeFen(setupFen));
      viewer.toggle();
      board = Chess.initial;
      await viewer.rebuild();
      expect(
        board.fen,
        Chess.initial.fen,
        reason: 'hidden build cannot move board',
      );
      await viewer.enter();
      expect(normalizeFen(board.fen), normalizeFen(setupFen));
    },
  );

  test('leaving during first build cannot steal the game board', () async {
    final games = [entry(chapter)];
    Position board = Chess.fromSetup(Setup.parseFen(setupFen));
    final viewer = ViewerOpeningTree(
      isActive: () => true,
      onChanged: () {},
      filteredGames: () => games,
      allGames: () => games,
      fenIndex: () => null,
      currentFen: () => board.fen,
      applyPosition: (position) => board = position,
    );
    final building = viewer.enter();
    viewer.hide();
    board = Chess.initial;
    await building;
    expect(board.fen, Chess.initial.fen);
  });
}

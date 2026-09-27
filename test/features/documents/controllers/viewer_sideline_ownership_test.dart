import 'package:chess_auto_prep/chess_core/pgn/pgn_parser.dart';
import 'package:chess_auto_prep/features/documents/models/solitaire_reveal.dart';
import 'package:chess_auto_prep/features/documents/controllers/viewer_game_controller.dart';
import 'package:chess_auto_prep/models/move_tree.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

const fixture =
    '1. e4 (1. d4 {Root} d5 (1... Nf6) 2. c4) '
    '(1. c4 e5) e5 (1... c5) 2. Nf3 *';

ViewerGameController loaded() =>
    ViewerGameController()..load(parsePgnGame(fixture));

void main() {
  test('forest, nodes and cursor publish detached immutable values', () {
    final controller = loaded();
    final forest = controller.variationsByPly;
    final root = forest[0]!.first;
    expect(root, isNot(isA<MoveNode>()));
    expect(() => forest.clear(), throwsUnsupportedError);
    expect(() => forest[0]!.clear(), throwsUnsupportedError);
    expect(() => root.children.clear(), throwsUnsupportedError);
    controller.goToAnalysisNode(root, 0);
    expect(() => controller.analysisPath.clear(), throwsUnsupportedError);
    controller.toggleNodeNag(root, 1);
    final updated = controller.findNodeById(root.id)!;
    expect(updated.nags, [1]);
    expect(() => updated.nags!.clear(), throwsUnsupportedError);
    expect(root.nags, isNull);
    expect(controller.setNodeComment(root, 'Changed'), isTrue);
    expect(root.comment, 'Root');
    expect(controller.findNodeById(root.id)!.comment, 'Changed');
  });

  test('local edits share other branches and navigation reuses the forest', () {
    final controller = loaded();
    final before = controller.variationsByPly;
    final root = before[0]!.first;
    final child = root.children.first;
    controller.goToAnalysisNode(child, 0);
    final path = controller.analysisPath;
    expect(controller.analysisPath, same(path));
    expect(controller.variationsByPly, same(before));
    controller.setNodeComment(child, 'New note');
    final after = controller.variationsByPly;
    expect(after[1], same(before[1]));
    expect(after[0]![1], same(before[0]![1]));
    expect(after[0]!.first.children[1], same(root.children[1]));
    expect(after[0]!.first.children.first.children, child.children);
    expect(controller.analysisPath.last.comment, 'New note');
    expect(path.last.comment, isNull);
    expect(controller.setNodeComment(child, 'New note'), isFalse);
    expect(controller.variationsByPly, same(after));
    controller.goToAnalysisNode(root, 0);
    controller.addMove('d5', editing: false, allowMainline: true);
    expect(controller.variationsByPly, same(after));
    controller.goToMainLineMove(2);
    expect(controller.variationsByPly, same(after));
  });

  test('adding and promoting scratch moves revises only their ancestry', () {
    final controller = loaded();
    final before = controller.variationsByPly;
    final root = before[0]!.first;
    controller.goToAnalysisNode(root, 0);
    controller.addMove('e5', editing: false, allowMainline: true);
    final scratch = controller.analysisPath.last;
    final withScratch = controller.variationsByPly;
    expect(root.children, hasLength(2));
    expect(withScratch[0]!.first.children, hasLength(3));
    expect(withScratch[0]!.first.children.first, same(root.children.first));
    expect(withScratch[1], same(before[1]));
    expect(scratch.isEphemeral, isTrue);
    controller.setNodeComment(scratch, 'Saved sideline');
    expect(scratch.isEphemeral, isTrue);
    expect(controller.findNodeById(scratch.id)!.isEphemeral, isFalse);
    expect(controller.buildAnnotatedMovetext(), contains('Saved sideline'));
  });

  test('deleted and replaced node commands are rejected without new views', () {
    final controller = loaded();
    final root = controller.variationsByPly[0]!.first;
    controller.deleteAnalysisNode(root.id);
    final deleted = controller.variationsByPly;
    expect(controller.setNodeComment(root, 'Late'), isFalse);
    expect(controller.toggleNodeNag(root, 2), isFalse);
    expect(controller.promoteNodeLineage(root), isFalse);
    expect(controller.goToAnalysisNode(root, 0), isFalse);
    expect(controller.variationsByPly, same(deleted));
    final old = controller.variationsByPly[1]!.single;
    controller.load(parsePgnGame(fixture));
    final replacement = controller.variationsByPly;
    expect(controller.setNodeComment(old, 'Wrong game'), isFalse);
    expect(controller.toggleNodeNag(old, 2), isFalse);
    expect(controller.deleteAnalysisNode(old.id), isFalse);
    expect(controller.variationsByPly, same(replacement));
    expect(controller.buildAnnotatedMovetext(), isNot(contains('Wrong game')));
  });

  test(
    'solitaire promotes an existing scratch child in the next projection',
    () {
      final controller = loaded();
      final root = controller.variationsByPly[0]!.first;
      controller.goToAnalysisNode(root, 0);
      controller.recordVariationMove('e5');
      final old = controller.variationsByPly[0]!.first.children.last;
      expect(old.isEphemeral, isTrue);
      expect(
        controller.addGuessNodeVariations({
          root.id: ['e5'],
        }),
        isTrue,
      );
      final current = controller.findNodeById(old.id)!;
      expect(current.isEphemeral, isFalse);
      expect(old.isEphemeral, isTrue);
      expect(
        controller.addGuessNodeVariations({
          root.id: ['e5'],
        }),
        isFalse,
      );
    },
  );

  test('deletion and scratch clearing retreat both the cursor and board', () {
    final controller = loaded();
    final root = controller.variationsByPly[0]!.first;
    controller.goToAnalysisNode(root.children.first.children.single, 0);
    controller.deleteAnalysisNode(root.children.first.id);
    expect(controller.analysisPath.single.id, root.id);
    expect(controller.currentPosition.fen, root.fen);
    controller.deleteAnalysisNode(root.id);
    expect(controller.analysisPath, isEmpty);
    expect(controller.currentPosition.fen, controller.startPosition.fen);
    controller.goToMainLineMove(1);
    controller.addMove('Nc6', editing: false, allowMainline: true);
    final saved = controller.variationsByPly[0];
    controller.clearAnalysis();
    expect(controller.currentPosition.fen, controller.mainline.at(1).fen);
    expect(controller.analysisPath, isEmpty);
    expect(controller.hasEphemeralMoves, isFalse);
    expect(controller.variationsByPly[0], same(saved));
  });

  test('solitaire reveal input cannot be changed behind the owner', () {
    final controller = loaded();
    final root = controller.variationsByPly[0]!.first;
    final ids = {root.id};
    controller.reveal = SolitaireReveal(
      mainlinePly: 0,
      nodeIds: ids,
      hidesUnreachedSidelines: true,
    );
    ids.clear();
    expect(controller.goToAnalysisNode(root, 0), isTrue);
    expect(() => controller.reveal!.nodeIds.clear(), throwsUnsupportedError);
  });

  test(
    '20,000-ply sideline capture, edit, serialize and delete are iterative',
    () {
      final game = PgnGame<PgnNodeData>(
        headers: {},
        comments: [],
        moves: PgnNode(),
      );
      game.moves.children.add(PgnChildNode(PgnNodeData(san: 'e4')));
      var parent = PgnChildNode(PgnNodeData(san: 'd4'));
      game.moves.children.add(parent);
      const cycle = ['Nf6', 'Nf3', 'Ng8', 'Ng1'];
      for (var i = 1; i < 20000; i++) {
        final child = PgnChildNode(PgnNodeData(san: cycle[(i - 1) % 4]));
        parent.children.add(child);
        parent = child;
      }
      final controller = ViewerGameController()..load(game);
      final before = controller.variationsByPly;
      var leaf = before[0]!.single;
      while (leaf.children.isNotEmpty) {
        leaf = leaf.children.single;
      }
      expect(controller.goToAnalysisNode(leaf, 0), isTrue);
      expect(controller.analysisPath, hasLength(20000));
      parent.data.comments = ['Incoming deep note'];
      expect(controller.adoptAnnotations(game), isTrue);
      expect(controller.analysisPath.last.comment, 'Incoming deep note');
      expect(leaf.comment, isNull);
      expect(controller.analysisPath.last.id, leaf.id);
      expect(controller.setNodeComment(leaf, 'Deep note'), isTrue);
      expect(controller.analysisPath.last.comment, 'Deep note');
      expect(leaf.comment, isNull);
      expect(controller.buildAnnotatedMovetext(), contains('Deep note'));
      controller.deleteAnalysisNode(before[0]!.single.id);
      expect(controller.variationsByPly, isEmpty);
      expect(controller.currentPosition.fen, controller.startPosition.fen);
    },
  );
}

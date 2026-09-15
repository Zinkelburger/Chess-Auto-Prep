import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/models/opening_tree.dart';
import 'package:chess_auto_prep/models/opening_tree_transfer.dart';
import 'package:chess_auto_prep/utils/fen_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('OpeningTreeTransfer', () {
    late OpeningTree tree;

    setUp(() {
      tree = OpeningTree(preserveSetupRoots: true);
      tree.appendLine(['e4', 'e5', 'Nf3']);
      tree.appendLine(['e4', 'c5']);
      tree.appendLine(['d4', 'Nf6']);
      tree.root.children['e4']!.updateStats(1.0);
      tree.root.children['d4']!.updateStats(0.0);
      // A chapter that starts from a set-up position.
      const setupFen = '4k3/8/8/8/8/8/8/4K2R w K - 0 1';
      tree.addSetupRoot(setupFen);
      tree.appendLineFromFen(setupFen, ['O-O']);
    });

    test('encodes only primitives, lists and maps', () {
      final json = OpeningTreeTransfer.encode(tree);
      expect(json['preserveSetupRoots'], isTrue);
      final nodes = json['nodes'] as List;
      expect(nodes.first, {
        'id': 0,
        'parentId': -1,
        'move': '',
        'fen': kStandardStartFen,
        'gamesPlayed': tree.root.gamesPlayed,
        'wins': 0,
        'losses': 0,
        'draws': 0,
        'childIds': isA<Map<String, int>>(),
      });
      expect(json.containsKey('fenToNodes'), isFalse);
    });

    test('round-trips structure, stats, parents and the FEN index', () {
      final copy = OpeningTreeTransfer.decode(OpeningTreeTransfer.encode(tree));

      expect(copy.preserveSetupRoots, isTrue);
      expect(copy.root.fen, tree.root.fen);
      expect(copy.root.gamesPlayed, tree.root.gamesPlayed);
      expect(copy.root.children.keys, unorderedEquals(['e4', 'd4']));

      final e4 = copy.root.children['e4']!;
      expect(e4.wins, 1);
      expect(e4.gamesPlayed, tree.root.children['e4']!.gamesPlayed);
      expect(identical(e4.parent, copy.root), isTrue);
      expect(e4.children['e5']!.children['Nf3']!.getMovePath(), [
        'e4',
        'e5',
        'Nf3',
      ]);

      expect(copy.setupRoots, hasLength(1));
      final setup = copy.setupRoots.single;
      expect(setup.parent, isNull);
      expect(setup.children.keys, ['O-O']);
      expect(copy.totalGames, tree.totalGames);

      for (final fen in [
        tree.root.fen,
        e4.fen,
        e4.children['c5']!.fen,
        setup.fen,
        setup.children['O-O']!.fen,
      ]) {
        expect(copy.fenToNodes[normalizeFen(fen)], hasLength(1), reason: fen);
      }
      expect(copy.fenToNodes.length, tree.fenToNodes.length);
    });

    test('the tree itself exposes the same encoding', () {
      expect(tree.toTransferJson(), OpeningTreeTransfer.encode(tree));
      final copy = OpeningTree.fromTransferJson(tree.toTransferJson());
      expect(copy.root.children.length, 2);
    });
  });
}

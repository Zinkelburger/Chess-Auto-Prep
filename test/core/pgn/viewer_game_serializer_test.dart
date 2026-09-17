import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/chess_core/pgn/viewer_game_serializer.dart';
import 'package:chess_auto_prep/models/move_tree.dart';

MoveNode _node(
  String san, {
  bool ephemeral = false,
  String? comment,
  List<int>? nags,
  List<MoveNode>? kids,
}) => MoveNode(
  san: san,
  fen: '',
  isEphemeral: ephemeral,
  comment: comment,
  nags: nags,
  children: kids,
);

String _movetext(PgnNode<PgnNodeData> tree) => PgnGame<PgnNodeData>(
  headers: {},
  moves: tree,
  comments: const [],
).makePgn().trim();

void main() {
  group('buildViewerPgnTree', () {
    test('synchronizing engine references never changes owner annotations', () {
      final move = PgnNodeData(
        san: 'e4',
        comments: ['Keep this [%bestline d4,d5,c4]'],
        startingComments: ['Before'],
        nags: [1],
      );
      final tree = buildViewerPgnTree(
        moveHistory: [move],
        sidelines: {
          0: [
            _node('d4', kids: [_node('d5')]),
          ],
        },
      );
      final serialized = tree.children.first.data;
      expect(serialized.comments, ['Keep this [%bestline d4,d5]']);
      expect(move.comments, ['Keep this [%bestline d4,d5,c4]']);
      serialized.startingComments!.clear();
      serialized.nags!.clear();
      expect(move.startingComments, ['Before']);
      expect(move.nags, [1]);
    });

    test('sidelines at ply p become siblings of mainline move p', () {
      final tree = buildViewerPgnTree(
        moveHistory: [
          PgnNodeData(san: 'e4'),
          PgnNodeData(san: 'e5'),
        ],
        sidelines: {
          0: [
            _node('d4', kids: [_node('d5')]),
          ],
          1: [_node('c5')],
          2: [_node('Nf3')],
        },
      );
      expect(
        _movetext(tree),
        '1. e4 ( 1. d4 d5 ) 1... e5 ( 1... c5 ) 2. Nf3 *',
      );
    });

    test('ephemeral roots and descendants never reach the tree', () {
      final tree = buildViewerPgnTree(
        moveHistory: [PgnNodeData(san: 'e4')],
        sidelines: {
          0: [
            _node('d4', ephemeral: true),
            _node('c4', kids: [_node('e5', ephemeral: true)]),
          ],
        },
      );
      expect(_movetext(tree), '1. e4 ( 1. c4 ) *');
    });
  });

  group('pgnNodeDataFor', () {
    test('carries a trimmed comment and a copy of the nags', () {
      final nags = [1];
      final data = pgnNodeDataFor(_node('e4', comment: ' good ', nags: nags));
      expect(data.san, 'e4');
      expect(data.comments, ['good']);
      expect(data.nags, [1]);
      nags.add(2);
      expect(data.nags, [1]);
    });

    test('omits empty comments and nags', () {
      final data = pgnNodeDataFor(_node('e4', comment: '  ', nags: []));
      expect(data.comments, isNull);
      expect(data.nags, isNull);
    });
  });

  group('buildLinePgn', () {
    final line = [PgnNodeData(san: 'e4'), PgnNodeData(san: 'e5')];

    test('writes numbered movetext without setup headers by default', () {
      expect(buildLinePgn(line), '1. e4 e5 *');
    });

    test('adds FEN and SetUp headers for a custom start', () {
      const fen = '4k3/8/8/8/8/8/4P3/4K3 w - - 0 1';
      final pgn = buildLinePgn([PgnNodeData(san: 'e4')], setupFen: fen);
      expect(pgn, contains('[FEN "$fen"]'));
      expect(pgn, contains('[SetUp "1"]'));
      expect(pgn, endsWith('\n\n1. e4 *'));
    });
  });
}

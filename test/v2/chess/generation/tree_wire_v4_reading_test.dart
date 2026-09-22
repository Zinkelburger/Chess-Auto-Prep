import 'dart:convert';

import 'package:chess_auto_prep/v2/chess/generation/search_node.dart';
import 'package:chess_auto_prep/v2/chess/generation/tree_wire_v4_reader.dart';
import 'package:flutter_test/flutter_test.dart';

import 'wire_documents.dart';

// What the reader makes of a document this codec did not write: the old Dart
// app's, the C builder's, one from a mode this search does not have, and one
// that is simply wrong. A file it cannot value has to say so — the one thing
// it may never do is answer with a tree that is not the saved one.
void main() {
  test('a tree from the heuristic search is refused, not read', () {
    final result = decodeTreeV4(
      wireDocument(tree: {...oneNode}..remove('history_aware')),
    );

    expect(result, isA<TreeUnsupported>());
    expect((result as TreeUnsupported).reason, contains('heuristic'));
  });

  test('a tree from an older format is refused', () {
    final result = decodeTreeV4(wireDocument(version: 3));

    expect(result, isA<TreeUnsupported>());
    expect((result as TreeUnsupported).reason, contains('version 3'));
  });

  test('a tree from the rolling search is refused', () {
    final result = decodeTreeV4(
      wireDocument(
        config: const {'algorithm_version': 3, 'search_algorithm': 'rolling'},
      ),
    );

    expect(result, isA<TreeUnsupported>());
    expect((result as TreeUnsupported).reason, contains('rolling'));
  });

  test('a tree from the bounded database mode is refused', () {
    final result = decodeTreeV4(
      wireDocument(
        config: const {
          'algorithm_version': 3,
          'search_algorithm': 'pure',
          'play_as_white': true,
          'max_depth': 4,
          'bounded_database': true,
        },
      ),
    );

    expect(result, isA<TreeUnsupported>());
    expect((result as TreeUnsupported).reason, contains('bounded database'));
  });

  test('text that is not a saved tree is malformed, never an exception', () {
    expect(decodeTreeV4('not json at all'), isA<TreeMalformed>());
    expect(decodeTreeV4('[1, 2, 3]'), isA<TreeMalformed>());
    expect(decodeTreeV4('{"format": "pgn"}'), isA<TreeMalformed>());
    expect(
      decodeTreeV4(jsonEncode({'format': 'opening_tree', 'version': 4})),
      isA<TreeMalformed>(),
    );
  });

  test('a node the build never evaluated is a frontier, not a failure', () {
    // The old builder attaches a position's replies before evaluating them,
    // so this is what a pause or a node budget leaves behind.
    final decoded = decodedTree(
      wireDocument(tree: {...oneNode}..remove('engine_eval_cp')),
    );

    expect(decoded.root, isA<FrontierNode>());
    expect(decoded.root.evalForUs.cp, 0, reason: 'neutral, not a guess');
    expect(decoded.root.valuation.value, 0.5);
    expect(decoded.root.valuation.isExact, isFalse);
  });

  test('an unevaluated node at the horizon is unfinished, not settled', () {
    final decoded = decodedTree(
      wireDocument(
        config: const {
          'algorithm_version': 3,
          'play_as_white': true,
          'max_depth': 0,
        },
        tree: {...oneNode}..remove('engine_eval_cp'),
      ),
    );

    expect(decoded.root, isA<FrontierNode>());
    expect(decoded.root.valuation.isExact, isFalse);
  });

  test('a tree saved without its positions is refused', () {
    final result = decodeTreeV4(
      wireDocument(tree: {...oneNode}..remove('fen')),
    );

    expect(result, isA<TreeUnsupported>());
    expect(
      (result as TreeUnsupported).reason,
      contains('without positions'),
      reason: 'the C builder can be told to leave them out',
    );
  });

  test('a tree that does not say which side it is for is refused', () {
    final result = decodeTreeV4(
      wireDocument(
        config: const {
          'algorithm_version': 3,
          'search_algorithm': 'pure',
          'max_depth': 4,
        },
      ),
    );

    expect(result, isA<TreeUnsupported>());
    expect((result as TreeUnsupported).reason, contains('which side'));
  });

  test('a tree that does not say how deep it is is refused', () {
    final result = decodeTreeV4(
      wireDocument(
        config: const {
          'algorithm_version': 3,
          'search_algorithm': 'pure',
          'play_as_white': true,
        },
      ),
    );

    expect(result, isA<TreeUnsupported>());
    expect((result as TreeUnsupported).reason, contains('how deep'));
  });

  test('a game that ended worth something impossible is malformed', () {
    final result = decodeTreeV4(
      wireDocument(tree: {...oneNode, 'terminal_value': 0.3}),
    );

    expect((result as TreeMalformed).detail, contains('neither a win'));
  });

  test('a mate worth the wrong side\'s result is malformed', () {
    // 0 is our loss, and we only lose a mate we are to move in. Here the
    // opponent is.
    final result = decodeTreeV4(
      wireDocument(
        tree: {
          ...oneNode,
          'fen': afterE4,
          'is_white_to_move': false,
          'terminal_value': 0.0,
        },
      ),
    );

    expect((result as TreeMalformed).detail, contains('checkmate worth 0.0'));
    expect(result.detail, contains(afterE4), reason: 'which node it was');
  });

  test('a tree nested deeper than any search goes is malformed', () {
    var node = <String, Object?>{
      ...oneNode,
      'move_uci': 'e2e4',
      'move_san': 'e4',
    };
    for (var depth = 0; depth < 600; depth++) {
      node = <String, Object?>{
        ...oneNode,
        'move_uci': 'e2e4',
        'move_san': 'e4',
        'children': [node],
      };
    }

    final result = decodeTreeV4(wireDocument(tree: node));

    expect((result as TreeMalformed).detail, contains('deeper than 512'));
  });

  test('moves survive a node that says it was never explored', () {
    // Expansions are atomic, so a node with children has all of them; the
    // flag only says whether the search went on below.
    final decoded = decodedTree(
      wireDocument(
        tree: {
          ...oneNode,
          'explored': false,
          'children': [
            {
              ...oneNode,
              'id': 2,
              'depth': 1,
              'move_uci': 'e2e4',
              'move_san': 'e4',
              'fen': afterE4,
              'is_white_to_move': false,
            },
          ],
        },
      ),
    );

    final root = decoded.root as OurNode;
    expect(root.candidates.single.move.uci, 'e2e4');
    expect(root.candidates.single.child.fen.value, afterE4);
  });

  test('a node that both ends the game and continues is malformed', () {
    final result = decodeTreeV4(
      wireDocument(
        tree: {
          ...oneNode,
          'terminal_value': 0.5,
          'children': [
            {
              ...oneNode,
              'id': 2,
              'depth': 1,
              'move_uci': 'e2e4',
              'move_san': 'e4',
              'fen': afterE4,
            },
          ],
        },
      ),
    );

    expect(result, isA<TreeMalformed>());
    expect((result as TreeMalformed).detail, contains('both ends the game'));
    expect(result.detail, contains(startPosition), reason: 'which node it was');
  });

  test('a child that does not name its move is malformed', () {
    final result = decodeTreeV4(
      wireDocument(
        tree: {
          ...oneNode,
          'children': [
            {...oneNode, 'id': 2, 'depth': 1},
          ],
        },
      ),
    );

    expect((result as TreeMalformed).detail, contains('name its move'));
  });

  test('replies that add up to less than a move are read as shares', () {
    // What the file records is what the model gave each reply when it was
    // written. An opponent node is an average over the replies it has, so
    // three quarters of a move spread over two of them is still all of what
    // this node can do.
    final decoded = decodedTree(
      wireDocument(
        tree: {
          ...oneNode,
          'children': [
            {
              ...oneNode,
              'id': 2,
              'depth': 1,
              'move_uci': 'e2e4',
              'move_san': 'e4',
              'fen': afterE4,
              'is_white_to_move': false,
              'children': [_reply('e7e5', 0.5, 3), _reply('c7c5', 0.25, 4)],
            },
          ],
        },
      ),
    );

    final opponent = (decoded.root as OurNode).chosen.child as OpponentNode;
    final shares = {
      for (final reply in opponent.replies) reply.move.uci: reply.probability,
    };
    expect(shares['e7e5']! + shares['c7c5']!, closeTo(1, 1e-12));
    expect(shares['e7e5'], closeTo(2 / 3, 1e-12));
    expect(shares['c7c5'], closeTo(1 / 3, 1e-12));
  });

  test('shares that already make a whole move are left alone', () {
    final decoded = decodedTree(
      wireDocument(
        tree: {
          ...oneNode,
          'children': [
            {
              ...oneNode,
              'id': 2,
              'depth': 1,
              'move_uci': 'e2e4',
              'move_san': 'e4',
              'fen': afterE4,
              'is_white_to_move': false,
              'children': [_reply('e7e5', 2 / 3, 3), _reply('c7c5', 1 / 3, 4)],
            },
          ],
        },
      ),
    );

    final opponent = (decoded.root as OurNode).chosen.child as OpponentNode;
    expect(
      opponent.replies.map((reply) => reply.probability),
      unorderedEquals(<double>[2 / 3, 1 / 3]),
      reason: 'exactly: the file carries the doubles themselves',
    );
  });

  test('a reply saved with no weight at all is malformed', () {
    final result = decodeTreeV4(
      wireDocument(
        tree: {
          ...oneNode,
          'is_white_to_move': false,
          'children': [_reply('e7e5', 1, 2), _reply('c7c5', 0, 3)],
        },
      ),
    );

    expect((result as TreeMalformed).detail, contains('no weight'));
  });
}

/// One reply of an opponent node, at the share the file gives it.
Map<String, Object?> _reply(String uci, double probability, int id) =>
    <String, Object?>{
      ...oneNode,
      'id': id,
      'depth': 2,
      'move_uci': uci,
      'move_san': uci,
      'move_probability': probability,
    };

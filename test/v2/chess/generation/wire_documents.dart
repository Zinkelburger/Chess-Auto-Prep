import 'dart:convert';

import 'package:chess_auto_prep/v2/chess/generation/tree_wire_v4_reader.dart';
import 'package:flutter_test/flutter_test.dart';

const startPosition =
    'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
const afterE4 = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';

/// The smallest node there is: one position, evaluated and unexpanded.
const oneNode = <String, Object?>{
  'id': 1,
  'depth': 0,
  'history_aware': true,
  'fen': startPosition,
  'is_white_to_move': true,
  'engine_eval_cp': 20,
};

/// A v4 document around [tree], under the configuration keys a reader needs
/// back. The defaults are the ordinary case, so a test overrides only the
/// part it is about.
String wireDocument({
  Object? version = 4,
  Map<String, Object?> config = const {
    'algorithm_version': 3,
    'search_algorithm': 'pure',
    'play_as_white': true,
    'max_depth': 4,
    'max_eval_loss_cp': 200,
  },
  Map<String, Object?> tree = oneNode,
}) => jsonEncode(<String, Object?>{
  'format': 'opening_tree',
  'version': version,
  'build_complete': true,
  'config': config,
  'tree': tree,
});

/// The tree [json] decodes to, failing the test when it does not decode.
TreeDecoded decodedTree(String json) {
  final result = decodeTreeV4(json);
  return result is TreeDecoded
      ? result
      : fail('expected a decoded tree, got $result');
}

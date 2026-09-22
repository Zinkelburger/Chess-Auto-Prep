/// Runs with the plain Dart VM: a Flutter/native dependency in the domain
/// closure is a compilation failure, independently of the Python import gate.
library;

import 'dart:convert';
import 'dart:math';

import 'package:chess_auto_prep/chess_core/generation/expectimax_probe_codec.dart';
import 'package:chess_auto_prep/chess_core/generation/trap_line_info.dart';
import 'package:chess_auto_prep/chess_core/generation/trap_reply.dart';
import 'package:chess_auto_prep/chess_core/generation/tree_serialization.dart';
import 'package:chess_auto_prep/chess_core/position/eval_canonicalize.dart';

void require(bool condition, String contract) {
  if (!condition) throw StateError(contract);
}

void main() {
  // Historical v3: selected scores and explored flags were not persisted.
  // Config is evidence, including unknown fields and a historical thread count;
  // decoding must not reinterpret it through today's runtime configuration.
  const legacyTree = '''{
    "format":"opening_tree","version":3,"total_nodes":2,"max_depth":1,
    "build_complete":false,"config":{"engine_threads":127,"unknown":[1,2]},
    "tree":{"id":4,"depth":0,"fen":"root w - - 0 1",
      "is_white_to_move":true,"children":[
      {"id":5,"depth":1,"fen":"child b - - 0 1","move_san":"e4",
       "move_uci":"e2e4","engine_eval_cp":-32,"is_repertoire_move":true,
       "local_cpl":0.0,"expectimax_value":0.6}]}}
  ''';
  final tree = deserializeTree(legacyTree);
  require(!tree.buildComplete, 'legacy partial status is preserved');
  require(tree.root.explored, 'legacy parent defaults to explored');
  require(
    tree.root.children.single.repertoireScore == .6,
    'legacy selected score uses expectimax',
  );
  require(
    identical(tree.root.children.single.parent, tree.root),
    'decoded parent identity is preserved',
  );
  require(
    tree.nodeIndex[5] == tree.root.children.single,
    'decoded flat index references canonical nodes',
  );
  require(
    tree.configSnapshot['engine_threads'] == 127,
    'artifact config is not clamped by runtime hardware',
  );
  final current = serializeTreeJson(tree);
  require(current['version'] == 4, 'writer keeps v4 format');
  require(
    jsonEncode(serializeTreeJson(deserializeTreeJson(current))) ==
        jsonEncode(current),
    'v4 round-trip preserves the document',
  );

  final random = Random(731);
  for (var sample = 0; sample < 64; sample++) {
    final document = jsonDecode(legacyTree) as Map<String, dynamic>;
    final child = ((document['tree'] as Map)['children'] as List).single as Map;
    final eval = random.nextInt(64001) - 32000;
    final probability = random.nextDouble();
    child['engine_eval_cp'] = eval;
    child['move_probability'] = probability;
    child['engine_pv'] = ['e2e4', 'e7e5'];
    final restored = deserializeTree(
      serializeTree(deserializeTreeJson(document)),
    );
    final node = restored.root.children.single;
    require(node.engineEvalCp == eval, 'seeded evaluation survives round-trip');
    require(
      node.moveProbability == probability,
      'seeded probability survives round-trip',
    );
    require(
      node.enginePv.join(' ') == 'e2e4 e7e5',
      'saved PV survives round-trip',
    );
  }

  final probes = ExpectimaxProbeCodec.decode(
    jsonEncode({
      'version': 1,
      'trees': [legacyTree, 7],
    }),
  );
  require(probes.length == 1, 'legacy probe reader ignores non-text entries');
  require(
    ExpectimaxProbeCodec.decode('{}').isEmpty,
    'legacy missing probe list remains empty',
  );
  require(
    ExpectimaxProbeCodec.decode(
          ExpectimaxProbeCodec.encode(probes),
        ).single.configSnapshot['engine_threads'] ==
        127,
    'probe round-trip retains historical config',
  );

  final trap = TrapLineInfo.fromJson(
    jsonDecode('''{
    "moves_san":["e4","e5"],"trap_score":0.3,"popular_prob":0.2,
    "popular_move":"f6","best_move":"Nc6","popular_eval_cp":180,
    "best_eval_cp":30,"eval_diff_cp":150,"cumulative_prob":0.4,
    "trick_surplus":0.2,"expectimax_value":0.6,"wp_eval":0.4,
    "all_replies":[{"san":"f6","probability":0.2,"eval_after_cp":180}]
  }''')
        as Map<String, dynamic>,
  );
  require(trap.fen == null, 'old trap files need no position field');
  require(
    trap.allReplies!.single.classification == TrapReplyClass.good,
    'legacy unclassified reply keeps its default',
  );
  require(
    TrapLineInfo.fromJson(trap.toJson()).evalDiffCp == 150,
    'trap analysis round-trips',
  );
  require(
    canonicalizeFen4('position b KQ - 17 42') == 'position b KQ -',
    'persistent FEN keys keep exact four-field reduction',
  );
  // CLI contract runner output.
  // ignore: avoid_print
  print('Pure Dart artifact contracts passed: v3/v4 tree, probes, traps, FEN.');
}

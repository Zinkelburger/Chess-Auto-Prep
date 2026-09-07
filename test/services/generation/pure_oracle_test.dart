import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/services/generation/tree_serialization.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/generation/eca_calculator.dart';
import 'package:chess_auto_prep/services/generation/repertoire_selector.dart';
import 'package:chess_auto_prep/models/build_tree_node.dart';

void main() {
  test(
    '30 independently solved full trees: values, bounds, policy and round trip',
    () {
      final cases =
          jsonDecode(
                File(
                  'test/fixtures/pure_expectimax_oracles.json',
                ).readAsStringSync(),
              )
              as List;
      for (final raw in cases) {
        final data = Map<String, dynamic>.from(raw as Map);
        final tree = deserializeTreeJson(data);
        final config = TreeBuildConfig.fromJson(
          Map<String, dynamic>.from(data['config'] as Map),
          startFen: tree.root.fen,
        );
        final calc = ExpectimaxCalculator(config: config);
        calc.calculate(tree);
        RepertoireSelector(config: config, ecaCalc: calc).select(tree);
        void check(BuildTreeNode node, Map expected) {
          expect(
            node.expectimaxValue,
            closeTo((expected['expected_value'] as num).toDouble(), 1e-12),
          );
          expect(node.valueLower, closeTo(node.expectimaxValue, 1e-12));
          expect(node.valueUpper, closeTo(node.expectimaxValue, 1e-12));
          if (expected.containsKey('expected_pick')) {
            expect(
              calc.scoreOurMoveChildren(node)!.child.nodeId,
              expected['expected_pick'],
            );
          }
          final children = (expected['children'] as List?) ?? [];
          for (final c in node.children) {
            check(c, children.firstWhere((e) => e['id'] == c.nodeId) as Map);
          }
        }

        check(tree.root, data['tree'] as Map);
        final restored = deserializeTreeJson(serializeTreeJson(tree));
        calc.calculate(restored);
        check(restored.root, data['tree'] as Map);
      }
    },
  );
}

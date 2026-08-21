import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/eca_calculator.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/generation/repertoire_selector.dart';
import 'package:chess_auto_prep/services/generation/skeleton_plan.dart';
import 'package:chess_auto_prep/utils/fen_utils.dart' show normalizeFen;
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

const _start = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

/// A real position reached from SANs, as a FEN.
String _fen(String sans) {
  Position pos = Chess.initial;
  for (final tok in sans.split(RegExp(r'\s+'))) {
    final t = tok.replaceAll(RegExp(r'^\d+\.(\.\.)?'), '');
    if (t.isEmpty) continue;
    pos = pos.play(pos.parseSan(t)!);
  }
  return pos.fen;
}

String _uci(String beforeSans, String san) {
  Position pos = Chess.initial;
  for (final tok in beforeSans.split(RegExp(r'\s+'))) {
    final t = tok.replaceAll(RegExp(r'^\d+\.(\.\.)?'), '');
    if (t.isEmpty) continue;
    pos = pos.play(pos.parseSan(t)!);
  }
  final m = pos.parseSan(san)! as NormalMove;
  return m.uci;
}

BuildTreeNode _n({
  required String fen,
  required String san,
  required String uci,
  required int ply,
  required bool whiteToMove,
  double expectimax = 0.5,
  int? evalCp,
  double moveProb = 1.0,
}) {
  final node =
      BuildTreeNode(
          fen: fen,
          moveSan: san,
          moveUci: uci,
          ply: ply,
          isWhiteToMove: whiteToMove,
          nodeId: '$san@$ply-$uci'.hashCode,
          moveProbability: moveProb,
          cumulativeProbability: 1.0,
        )
        ..expectimaxValue = expectimax
        ..hasExpectimax = true;
  if (evalCp != null) node.engineEvalCp = evalCp;
  return node;
}

List<String> _selected(BuildTree tree, TreeBuildConfig config) {
  RepertoireSelector(
    config: config,
    ecaCalc: ExpectimaxCalculator(config: config),
  ).select(tree);
  final out = <String>[];
  void walk(BuildTreeNode n) {
    if (n.isRepertoireMove) out.add(n.moveSan);
    for (final c in n.children) {
      walk(c);
    }
  }

  walk(tree.root);
  return out;
}

void main() {
  // Black to move after 1.d4 Nf6 2.Nf3 — a Benko player's node. Two candidate
  // replies: ...c5 (the consistent move) and ...d5 (a QGD-ish move) with a
  // slightly BETTER engine eval, so only a skeleton signal picks ...c5.
  BuildTree nf3Tree({required int c5Cp, required int d5Cp}) {
    final rootFen = _fen('1.d4 Nf6 2.Nf3'); // black to move
    final root = _n(fen: rootFen, san: '', uci: '', ply: 2, whiteToMove: false);
    final c5 = _n(
      fen: _fen('1.d4 Nf6 2.Nf3 c5'),
      san: 'c5',
      uci: _uci('1.d4 Nf6 2.Nf3', 'c5'),
      ply: 3,
      whiteToMove: true,
      evalCp: c5Cp, // white-to-move-relative; evalForUs(black) negates
      expectimax: 0.50,
    );
    final d5 = _n(
      fen: _fen('1.d4 Nf6 2.Nf3 d5'),
      san: 'd5',
      uci: _uci('1.d4 Nf6 2.Nf3', 'd5'),
      ply: 3,
      whiteToMove: true,
      evalCp: d5Cp,
      expectimax: 0.55, // d5 looks a touch better by default
    );
    root.children.addAll([c5, d5]);
    for (final c in root.children) {
      c.parent = root;
    }
    return BuildTree(root: root);
  }

  SkeletonPlan benkoPlan() => SkeletonPlan(
    nodes: SkeletonPlan.parseLines(const [
      '1.d4 Nf6 2.c4 c5 3.Nf3 cxd4 4.Nxd4 e5',
      '1.d4 Nf6 2.c4 c5 3.d5 b5 4.cxb5 a6 5.bxa6 e6',
    ], playAsWhite: false),
  );

  test('with no plan, the better-expectimax move (d5) is chosen', () {
    final tree = nf3Tree(c5Cp: 10, d5Cp: 10);
    const config = TreeBuildConfig(startFen: _start, playAsWhite: false);
    expect(_selected(tree, config), ['d5']);
  });

  test('transfer bias picks ...c5 from the skeleton at 2.Nf3', () {
    // c5 and d5 both sound (within 50cp); default pick is d5. Skeleton played
    // ...c5 after 2.c4 (4 squares away) → transfer overrides to c5.
    final tree = nf3Tree(c5Cp: 10, d5Cp: 10);
    final config = const TreeBuildConfig(
      startFen: _start,
      playAsWhite: false,
    ).copyWith(skeletonPlan: benkoPlan());
    expect(_selected(tree, config), ['c5']);
  });

  test('transfer does not override when the transfer move is unsound', () {
    // ...c5 now loses 120cp vs ...d5 → outside the 50cp window → d5 stands.
    final tree = nf3Tree(c5Cp: 130, d5Cp: 10);
    final config = const TreeBuildConfig(
      startFen: _start,
      playAsWhite: false,
    ).copyWith(skeletonPlan: benkoPlan());
    expect(_selected(tree, config), ['d5']);
  });

  test('a pin is honoured even when it is the worse move', () {
    // Pin ...d5 at 2.Nf3 even though c5 is better — a pin is the user's call.
    final tree = nf3Tree(c5Cp: 40, d5Cp: 10);
    final pinFen = normalizeFen(_fen('1.d4 Nf6 2.Nf3'));
    final plan = SkeletonPlan(
      nodes: [
        SkeletonNode(
          fen: pinFen,
          uci: _uci('1.d4 Nf6 2.Nf3', 'd5'),
          pathLabel: '1.d4 Nf6 2.Nf3',
        ),
      ],
    );
    final config = const TreeBuildConfig(
      startFen: _start,
      playAsWhite: false,
    ).copyWith(skeletonPlan: plan);
    expect(_selected(tree, config), ['d5']);
  });

  test('structure veto drops ...d5 (pawn on d5) in favour of ...c5', () {
    // Both sound and NO transfer targets (empty node list) — only the veto
    // acts. ...d5 puts a black pawn on d5 → vetoed → c5 chosen.
    final tree = nf3Tree(c5Cp: 10, d5Cp: 25); // d5 better by eval
    final config = const TreeBuildConfig(startFen: _start, playAsWhite: false)
        .copyWith(
          skeletonPlan: const SkeletonPlan(
            features: [PawnOnSquare(square: 'd5')],
          ),
        );
    expect(_selected(tree, config), ['c5']);
  });
}

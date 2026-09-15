import 'package:chess_auto_prep/features/audit/services/repertoire_walk.dart';
import 'package:chess_auto_prep/models/opening_tree.dart';
import 'package:chess_auto_prep/services/opening_tree_builder.dart';
import 'package:flutter_test/flutter_test.dart';

/// White repertoire with an owner choice at move 2: after 1.e4 e5 White
/// plays 2.Nf3 in three games and 2.Bc4 in one game. The attacker (Black)
/// branches at move 1 with 1...e5 and 1...c5 — attacker branching must NOT
/// attenuate reach probability, owner branching must.
const _games = [
  '[Result "1-0"]\n\n1. e4 e5 2. Nf3 Nc6 1-0',
  '[Result "1-0"]\n\n1. e4 e5 2. Nf3 Nc6 1-0',
  '[Result "1-0"]\n\n1. e4 e5 2. Nf3 Nf6 1-0',
  '[Result "1-0"]\n\n1. e4 e5 2. Bc4 Nf6 1-0',
  '[Result "1-0"]\n\n1. e4 c5 2. Nf3 d6 1-0',
];

/// Walk [root] with the hunt's enqueue rule, returning cumProb per FEN.
Map<String, double> propagate(OpeningTreeNode root, bool isWhiteRepertoire) {
  final out = <String, double>{};
  void visit(RepertoireWalkEntry entry) {
    out[entry.fen] = entry.cumulativeProbability;
    final isOwnerTurn = entry.whiteToMove == isWhiteRepertoire;
    entry.children(attenuate: isOwnerTurn).forEach(visit);
  }

  visit(
    RepertoireWalkEntry(
      node: root,
      movePath: const [],
      ply: 0,
      cumulativeProbability: 1.0,
    ),
  );
  return out;
}

void main() {
  test('owner branching attenuates, attacker branching does not', () async {
    final tree = await OpeningTreeBuilder.buildTree(
      pgnList: _games,
      username: '',
      userIsWhite: true,
      strictPlayerMatching: false,
      maxDepth: 10,
    );

    final root = tree.root;
    final e4 = root.children['e4']!;
    final e5 = e4.children['e5']!;
    final c5 = e4.children['c5']!;
    final nf3 = e5.children['Nf3']!;
    final bc4 = e5.children['Bc4']!;

    final probs = propagate(root, true);

    // Owner (White) to move at root: 1.e4 is the only child — no split.
    expect(probs[e4.fen], 1.0);

    // Attacker (Black) to move after 1.e4: both replies keep probability 1,
    // even though the file has 4 games of 1...e5 vs 1 of 1...c5.
    expect(probs[e5.fen], 1.0);
    expect(probs[c5.fen], 1.0);

    // Owner to move after 1.e4 e5: 2.Nf3 (3 games) vs 2.Bc4 (1 game)
    // attenuates by games share.
    expect(probs[nf3.fen], closeTo(0.75, 1e-9));
    expect(probs[bc4.fen], closeTo(0.25, 1e-9));

    // Deeper attacker branching under 2.Nf3 inherits 0.75 unchanged.
    final nc6 = nf3.children['Nc6']!;
    final nf6 = nf3.children['Nf6']!;
    expect(probs[nc6.fen], closeTo(0.75, 1e-9));
    expect(probs[nf6.fen], closeTo(0.75, 1e-9));
  });
}

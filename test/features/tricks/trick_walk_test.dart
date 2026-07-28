import 'package:chess_auto_prep/features/tricks/services/trick_scoring.dart';
import 'package:chess_auto_prep/models/opening_tree.dart';
import 'package:chess_auto_prep/services/opening_tree_builder.dart';
import 'package:flutter_test/flutter_test.dart';

/// Owner is White: 2.Nf3 in three games vs 2.Bc4 in one after 1.e4 e5
/// (owner branching → attenuates), plus one 1...c5 game (opponent branching
/// as seen from the trickster — must NOT attenuate when Black is the
/// trickster's opposite... i.e. only OWNER branching attenuates).
const _games = [
  '[Result "1-0"]\n\n1. e4 e5 2. Nf3 Nc6 3. Bb5 1-0',
  '[Result "1-0"]\n\n1. e4 e5 2. Nf3 Nc6 3. Bb5 1-0',
  '[Result "1-0"]\n\n1. e4 e5 2. Nf3 Nc6 3. Bb5 1-0',
  '[Result "1-0"]\n\n1. e4 e5 2. Bc4 Nf6 1-0',
  '[Result "1-0"]\n\n1. e4 c5 2. Nf3 d6 1-0',
];

Future<OpeningTree> buildTree() => OpeningTreeBuilder.buildTree(
  pgnList: _games,
  username: '',
  userIsWhite: true,
  strictPlayerMatching: false,
  maxDepth: 10,
);

double reachOf(List<TrickTarget> targets, String fen) =>
    targets.singleWhere((t) => t.fen == fen).reach;

void main() {
  test('White owner: trickster (Black) targets, leaves included', () async {
    final tree = await buildTree();
    final root = tree.root;
    final e4 = root.children['e4']!;
    final e5 = e4.children['e5']!;
    final nf3 = e5.children['Nf3']!;
    final bc4 = e5.children['Bc4']!;
    final nc6 = nf3.children['Nc6']!;
    final bb5 = nc6.children['Bb5']!;

    final walk = collectTrickTargets(root, playerIsWhite: true, maxPly: 10);
    final targets = walk.targets;
    final fens = targets.map((t) => t.fen).toSet();

    // All 11 nodes visited.
    expect(walk.nodesWalked, 11);

    // Black-to-move positions only; owner-to-move positions are absent.
    expect(fens.contains(root.fen), isFalse);
    expect(fens.contains(e5.fen), isFalse);
    expect(fens.contains(nc6.fen), isFalse);

    // Trickster branching does not attenuate reach…
    expect(reachOf(targets, e4.fen), closeTo(1.0, 1e-9));
    // …owner branching does (3 of 4 games play 2.Nf3).
    expect(reachOf(targets, nf3.fen), closeTo(0.75, 1e-9));
    expect(reachOf(targets, bc4.fen), closeTo(0.25, 1e-9));

    // The childless 3.Bb5 position is a target too — that is where the
    // hunt extends past the recorded games.
    expect(reachOf(targets, bb5.fen), closeTo(0.75, 1e-9));
    expect(targets.singleWhere((t) => t.fen == bb5.fen).movePath, [
      'e4',
      'e5',
      'Nf3',
      'Nc6',
      'Bb5',
    ]);
  });

  test('Black owner: roles invert, root becomes a target', () async {
    final tree = await buildTree();
    final root = tree.root;
    final e4 = root.children['e4']!;
    final e5 = e4.children['e5']!;
    final c5 = e4.children['c5']!;
    final nc6 = e5.children['Nf3']!.children['Nc6']!;

    final walk = collectTrickTargets(root, playerIsWhite: false, maxPly: 10);
    final targets = walk.targets;

    // Trickster is White now, so the root itself is probeable.
    expect(reachOf(targets, root.fen), closeTo(1.0, 1e-9));

    // Owner (Black) branches 1...e5 (4 games) vs 1...c5 (1 game).
    expect(reachOf(targets, e5.fen), closeTo(0.8, 1e-9));
    expect(reachOf(targets, c5.fen), closeTo(0.2, 1e-9));

    // White's own 2.Nf3/2.Bc4 split does not attenuate: after 2.Nf3 Nc6
    // the reach is still 0.8.
    expect(reachOf(targets, nc6.fen), closeTo(0.8, 1e-9));
  });

  test('maxPly cuts the walk', () async {
    final tree = await buildTree();
    final walk = collectTrickTargets(tree.root, playerIsWhite: true, maxPly: 3);
    // root, e4, e5, c5, Nf3(e5), Bc4, Nf3(c5) — plies 0..3.
    expect(walk.nodesWalked, 7);
    // Targets at ply <= 3: after 1.e4, and the three ply-3 knight/bishop
    // moves; the deeper 3.Bb5 leaf is out.
    expect(walk.targets.length, 4);
  });
}

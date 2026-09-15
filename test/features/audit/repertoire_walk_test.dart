/// [RepertoireWalk]: the breadth-first sweep the audit and the hole hunt
/// share — visit order and paths, the ply limit, progress cadence, reach
/// attenuation for either side, and the cooperative cancel/pause.
library;

import 'package:chess_auto_prep/features/audit/services/repertoire_walk.dart';
import 'package:chess_auto_prep/models/opening_tree.dart';
import 'package:chess_auto_prep/services/opening_tree_builder.dart';
import 'package:chess_auto_prep/services/run_control.dart';
import 'package:flutter_test/flutter_test.dart';

/// White plays 1.e4; Black answers 1...e5 three times and 1...c5 once; after
/// 1...e5 White chooses 2.Nf3 twice and 2.Bc4 once.
const _games = [
  '[Result "*"]\n\n1. e4 e5 2. Nf3 Nc6 *',
  '[Result "*"]\n\n1. e4 e5 2. Nf3 Nc6 *',
  '[Result "*"]\n\n1. e4 e5 2. Bc4 Nf6 *',
  '[Result "*"]\n\n1. e4 c5 *',
];

Future<OpeningTree> _build() => OpeningTreeBuilder.buildTree(
  pgnList: _games,
  username: '',
  userIsWhite: true,
  strictPlayerMatching: false,
  maxDepth: 10,
);

void main() {
  late OpeningTree tree;

  OpeningTreeNode at(List<String> path) {
    var node = tree.root;
    for (final san in path) {
      node = node.children[san]!;
    }
    return node;
  }

  setUp(() async {
    tree = await _build();
  });

  /// Every entry the walk visits, in order.
  Future<List<RepertoireWalkEntry>> visitAll(
    RepertoireWalk walk, {
    void Function(RepertoireWalkEntry)? onProgress,
  }) async {
    final visited = <RepertoireWalkEntry>[];
    await walk.run(
      visit: (entry) async => visited.add(entry),
      onProgress: onProgress,
    );
    return visited;
  }

  test('visits breadth-first with the full path from the tree root', () async {
    final walk = RepertoireWalk(
      start: tree.root,
      maxPly: 30,
      attenuatingSideIsWhite: false,
      control: RunControl(),
    );

    final visited = await visitAll(walk);

    expect(visited.map((e) => e.movePath.join(' ')), [
      '',
      'e4',
      'e4 e5',
      'e4 c5',
      'e4 e5 Nf3',
      'e4 e5 Bc4',
      'e4 e5 Nf3 Nc6',
      'e4 e5 Bc4 Nf6',
    ]);
    expect(visited.map((e) => e.ply), [0, 1, 2, 2, 3, 3, 4, 4]);
    expect(walk.visited, 8);
    expect(walk.totalNodes, 8);
    expect(visited.first.whiteToMove, isTrue);
    expect(visited[1].whiteToMove, isFalse);
    expect(visited.where((e) => e.isLeaf).map((e) => e.movePath.last), [
      'c5',
      'Nc6',
      'Nf6',
    ]);
  });

  test('a subtree start keeps the path to it', () async {
    final walk = RepertoireWalk(
      start: at(['e4', 'e5']),
      maxPly: 30,
      attenuatingSideIsWhite: false,
      control: RunControl(),
    );

    final visited = await visitAll(walk);

    expect(visited.first.movePath, ['e4', 'e5']);
    expect(visited.first.ply, 0);
    expect(visited.map((e) => e.movePath.last), [
      'e5',
      'Nf3',
      'Bc4',
      'Nc6',
      'Nf6',
    ]);
  });

  test('maxPly visits the boundary ply and nothing below it', () async {
    final walk = RepertoireWalk(
      start: tree.root,
      maxPly: 1,
      attenuatingSideIsWhite: false,
      control: RunControl(),
    );

    final visited = await visitAll(walk);

    expect(visited.map((e) => e.movePath.join(' ')), ['', 'e4']);
    expect(walk.totalNodes, 2, reason: 'the progress denominator matches');
    expect(visited.last.isLeaf, isFalse, reason: 'pruned, not a leaf');
  });

  test('progress fires every fifth position and on the last', () async {
    final walk = RepertoireWalk(
      start: tree.root,
      maxPly: 30,
      attenuatingSideIsWhite: false,
      control: RunControl(),
    );
    final reported = <int>[];

    await visitAll(walk, onProgress: (_) => reported.add(walk.visited));

    expect(reported, [5, 8]);
  });

  group('reach attenuation', () {
    test('charges the attenuating side\'s alternatives only', () async {
      // The audit's rule for a White repertoire: Black's branching attenuates.
      final walk = RepertoireWalk(
        start: tree.root,
        maxPly: 30,
        attenuatingSideIsWhite: false,
        control: RunControl(),
      );

      final visited = await visitAll(walk);
      final reach = {
        for (final e in visited) e.movePath.join(' '): e.cumulativeProbability,
      };

      expect(reach['e4'], 1.0);
      expect(reach['e4 e5'], closeTo(0.75, 1e-9));
      expect(reach['e4 c5'], closeTo(0.25, 1e-9));
      // White's own choice at move 2 is free.
      expect(reach['e4 e5 Nf3'], closeTo(0.75, 1e-9));
      expect(reach['e4 e5 Bc4'], closeTo(0.75, 1e-9));
      expect(reach['e4 e5 Nf3 Nc6'], closeTo(0.75, 1e-9));
    });

    test('the other side keeps the parent\'s probability', () async {
      // The hunt's rule for a White repertoire: White's branching attenuates.
      final walk = RepertoireWalk(
        start: tree.root,
        maxPly: 30,
        attenuatingSideIsWhite: true,
        control: RunControl(),
      );

      final visited = await visitAll(walk);
      final reach = {
        for (final e in visited) e.movePath.join(' '): e.cumulativeProbability,
      };

      expect(reach['e4 e5'], 1.0);
      expect(reach['e4 c5'], 1.0);
      expect(reach['e4 e5 Nf3'], closeTo(2 / 3, 1e-9));
      expect(reach['e4 e5 Bc4'], closeTo(1 / 3, 1e-9));
    });

    test('children of a node with no games inherit the reach', () {
      final entry = RepertoireWalkEntry(
        node: OpeningTreeNode(move: '', fen: tree.root.fen)
          ..getOrCreateChild('e4', at(['e4']).fen)
          ..getOrCreateChild('d4', at(['e4']).fen),
        movePath: const [],
        ply: 0,
        cumulativeProbability: 0.5,
      );

      final children = entry.children(attenuate: true);

      expect(children.map((c) => c.cumulativeProbability), [0.5, 0.5]);
      expect(children.map((c) => c.movePath), [
        ['e4'],
        ['d4'],
      ]);
      expect(children.map((c) => c.ply), [1, 1]);
    });
  });

  group('run control', () {
    test('a cancel during a visit ends the walk there', () async {
      final control = RunControl();
      final walk = RepertoireWalk(
        start: tree.root,
        maxPly: 30,
        attenuatingSideIsWhite: false,
        control: control,
      );
      final visited = <String>[];

      await walk.run(
        visit: (entry) async {
          visited.add(entry.movePath.join(' '));
          if (entry.movePath.length == 2) control.cancel();
        },
      );

      expect(visited, ['', 'e4', 'e4 e5']);
      expect(walk.visited, 3);
    });

    test('a paused walk holds at the next position until resumed', () async {
      final control = RunControl();
      final walk = RepertoireWalk(
        start: tree.root,
        maxPly: 30,
        attenuatingSideIsWhite: false,
        control: control,
      );
      final visited = <String>[];

      final run = walk.run(
        visit: (entry) async {
          visited.add(entry.movePath.join(' '));
          if (entry.movePath.length == 1) control.pause();
        },
      );
      await Future<void>.delayed(RunControl.pollInterval * 3);
      expect(visited, ['', 'e4']);

      control.resume();
      await run;
      expect(visited, hasLength(8));
    });
  });
}

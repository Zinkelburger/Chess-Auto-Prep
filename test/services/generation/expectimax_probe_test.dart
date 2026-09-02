// The on-demand expectimax pieces: grafting a probe into the tree that holds
// its root, finding which tree owns a node, re-scoring after a graft, and the
// probe store's round trip.

import 'package:chess_auto_prep/core/generated_repertoire.dart';
import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/expectimax_probe.dart';
import 'package:chess_auto_prep/services/generation/fen_map.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:flutter_test/flutter_test.dart';

const _start = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
const _afterE4 = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';
const _afterE4C5 =
    'rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq c6 0 2';
const _afterE4E5 =
    'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2';
const _afterE4C5Nf3 =
    'rnbqkbnr/pp1ppppp/8/2p5/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2';
const _afterD4 = 'rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq - 0 1';

BuildTreeNode _node({
  required String fen,
  required String san,
  required String uci,
  required int ply,
  required bool whiteToMove,
  required int id,
  BuildTreeNode? parent,
  double prob = 1.0,
  int? eval,
  bool explored = false,
}) {
  final n = BuildTreeNode(
    fen: fen,
    moveSan: san,
    moveUci: uci,
    ply: ply,
    isWhiteToMove: whiteToMove,
    nodeId: id,
    parent: parent,
    moveProbability: prob,
    cumulativeProbability: parent == null
        ? 1.0
        : parent.cumulativeProbability * (whiteToMove ? prob : 1.0),
  )..explored = explored;
  if (eval != null) n.engineEvalCp = eval;
  parent?.children.add(n);
  return n;
}

/// start → e4 (unexplored leaf, no eval) plus d4.
BuildTree _host() {
  final root = _node(
    fen: _start,
    san: '',
    uci: '',
    ply: 0,
    whiteToMove: true,
    id: 1,
    eval: 20,
    explored: true,
  );
  _node(
    fen: _afterE4,
    san: 'e4',
    uci: 'e2e4',
    ply: 1,
    whiteToMove: false,
    id: 2,
    parent: root,
    eval: 30,
  );
  _node(
    fen: _afterD4,
    san: 'd4',
    uci: 'd2d4',
    ply: 1,
    whiteToMove: false,
    id: 3,
    parent: root,
    eval: 25,
  );
  return BuildTree(root: root, totalNodes: 3, maxPlyReached: 1)
    ..computeMetadata();
}

/// Rooted after 1.e4: c5 (41%, with 2.Nf3 below) and e5 (30%).
BuildTree _probe() {
  final root = _node(
    fen: _afterE4,
    san: '',
    uci: '',
    ply: 0,
    whiteToMove: false,
    id: 1,
    eval: 30,
    explored: true,
  );
  final c5 = _node(
    fen: _afterE4C5,
    san: 'c5',
    uci: 'c7c5',
    ply: 1,
    whiteToMove: true,
    id: 2,
    parent: root,
    prob: 0.41,
    eval: 25,
    explored: true,
  );
  _node(
    fen: _afterE4C5Nf3,
    san: 'Nf3',
    uci: 'g1f3',
    ply: 2,
    whiteToMove: false,
    id: 3,
    parent: c5,
    eval: 28,
  );
  _node(
    fen: _afterE4E5,
    san: 'e5',
    uci: 'e7e5',
    ply: 1,
    whiteToMove: true,
    id: 4,
    parent: root,
    prob: 0.30,
    eval: 35,
  );
  return BuildTree(root: root, totalNodes: 4, maxPlyReached: 2)
    ..computeMetadata();
}

void main() {
  group('graftProbe', () {
    test('adds the probe below the matching node, rebased', () {
      final host = _host();
      final at = host.root.children.first;
      final added = graftProbe(
        host: host,
        at: at,
        probe: _probe(),
        playAsWhite: true,
      );

      expect(added, 3);
      expect(at.explored, isTrue);
      expect(at.children.map((c) => c.moveSan), ['c5', 'e5']);
      final c5 = at.children.first;
      expect(c5.ply, 2);
      expect(c5.children.single.ply, 3);
      // Black's reply shrinks reach; White's continuation does not.
      expect(c5.cumulativeProbability, closeTo(0.41, 1e-9));
      expect(c5.children.single.cumulativeProbability, closeTo(0.41, 1e-9));
      // Fresh ids, none colliding with the host's 1..3.
      final ids = host.nodeIndex.keys.toList()..sort();
      expect(ids, [1, 2, 3, 4, 5, 6]);
      expect(host.totalNodes, 6);
      expect(host.maxPlyReached, 3);
      expect(c5.parent, same(at));
    });

    test('completes children the host already has instead of duplicating', () {
      final host = _host();
      final at = host.root.children.first;
      // The host already knows 1...c5 but never evaluated or explored it.
      _node(
        fen: _afterE4C5,
        san: 'c5',
        uci: 'c7c5',
        ply: 2,
        whiteToMove: true,
        id: 4,
        parent: at,
        prob: 0.41,
      );
      host.computeMetadata();

      final added = graftProbe(
        host: host,
        at: at,
        probe: _probe(),
        playAsWhite: true,
      );

      // Nf3 under c5, and e5: the existing c5 is reused.
      expect(added, 2);
      expect(at.children.where((c) => c.moveSan == 'c5').length, 1);
      final c5 = at.children.firstWhere((c) => c.moveSan == 'c5');
      expect(c5.nodeId, 4);
      expect(c5.engineEvalCp, 25);
      expect(c5.explored, isTrue);
      expect(c5.children.single.moveSan, 'Nf3');
    });

    test('refuses a probe rooted at another position', () {
      final host = _host();
      expect(
        () => graftProbe(
          host: host,
          at: host.root,
          probe: _probe(),
          playAsWhite: true,
        ),
        throwsArgumentError,
      );
    });
  });

  test('treeOwning finds the tree whose root is above the node', () {
    final a = _host();
    final b = _probe();
    expect(treeOwning(a.root.children.last, [a, b]), same(a));
    expect(treeOwning(b.root.children.first.children.single, [a, b]), same(b));
    expect(treeOwning(_probe().root, [a, b]), isNull);
  });

  test('rescoreTree gives grafted nodes expectimax values', () {
    final host = _host();
    final at = host.root.children.first;
    graftProbe(host: host, at: at, probe: _probe(), playAsWhite: true);
    final config = TreeBuildConfig.formDefaults(
      startFen: _start,
      playAsWhite: true,
    );
    final fenMap = FenMap()..populate(host.root);

    rescoreTree(host, config, fenMap);

    expect(at.hasExpectimax, isTrue);
    for (final child in at.children) {
      expect(child.hasExpectimax, isTrue, reason: child.moveSan);
    }
    // Selection is not part of re-scoring: nothing gets starred.
    expect(host.root.children.any((c) => c.isRepertoireMove), isFalse);
  });

  test('ExpectimaxProbeStore round-trips every tree', () {
    final probe = _probe()..startMoves = 'e4';
    final other = _host();
    final raw = ExpectimaxProbeStore.encode([probe, other]);

    final back = ExpectimaxProbeStore.decode(raw);

    expect(back.length, 2);
    expect(back[0].root.fen, _afterE4);
    expect(back[0].startMoves, 'e4');
    expect(back[0].totalNodes, 4);
    expect(back[1].root.fen, _start);
    expect(back[1].root.children.length, 2);
  });

  test('ExpectimaxProbeStore.pathFor sits beside the repertoire', () {
    expect(
      ExpectimaxProbeStore.pathFor('/r/benko.pgn'),
      '/r/benko_expectimax.json',
    );
  });

  test('a bundle with probes finds their positions through its FenMap', () {
    final bundle = GeneratedRepertoire.fromTree(
      _host(),
      playAsWhite: true,
      probes: [_probe()],
    );
    expect(bundle.probes.length, 1);
    expect(bundle.allTrees.length, 2);
    // The map's expanded-wins rule: the host's e4 is a childless leaf, so
    // the probe's expanded root is the canonical node for that position —
    // which is what lets the pane list the probe's moves from there.
    final atE4 = bundle.fenMap.getCanonical(_afterE4)!;
    expect(atE4.children.map((c) => c.moveSan), ['c5', 'e5']);
    expect(bundle.fenMap.getCanonical(_afterE4C5Nf3)?.moveSan, 'Nf3');
  });
}

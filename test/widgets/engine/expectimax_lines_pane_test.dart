/// The expectimax pane is a read-only table of what the build stored: every
/// move at the position, its practical value beside the engine's, the chosen
/// move marked, and plain words — never a spinner — when the tree has
/// nothing for the position.
library;

import 'package:chess_auto_prep/core/board_preview_controller.dart';
import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/widgets/engine/expectimax_lines_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _startFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
const _afterE4 = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';
const _afterD4 = 'rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq - 0 1';
const _afterE4C5 =
    'rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq c6 0 2';
const _afterE4E5 =
    'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2';

BuildTreeNode _node({
  required String fen,
  required String san,
  required String uci,
  required int ply,
  required bool isWhiteToMove,
  double moveProbability = 0.0,
  int? evalCp,
  double expectimax = 0.5,
  bool isRepertoireMove = false,
}) {
  final n =
      BuildTreeNode(
          fen: fen,
          moveSan: san,
          moveUci: uci,
          ply: ply,
          isWhiteToMove: isWhiteToMove,
          nodeId: 0,
        )
        ..moveProbability = moveProbability
        ..expectimaxValue = expectimax
        ..hasExpectimax = true
        ..isRepertoireMove = isRepertoireMove;
  if (evalCp != null) n.engineEvalCp = evalCp;
  return n;
}

void _link(BuildTreeNode parent, BuildTreeNode child) {
  parent.children.add(child);
  child.parent = parent;
}

/// root (us) ── e4 ★ (V .62, +30) ── c5 41% (V .60) / e5 30% (V .65)
///           └─ d4   (V .55, +20)
BuildTree _tree(TreeBuildConfig config) {
  final root = _node(
    fen: _startFen,
    san: '',
    uci: '',
    ply: 0,
    isWhiteToMove: true,
    expectimax: 0.62,
    evalCp: 30,
  );
  final e4 = _node(
    fen: _afterE4,
    san: 'e4',
    uci: 'e2e4',
    ply: 1,
    isWhiteToMove: false,
    expectimax: 0.62,
    evalCp: 30,
    isRepertoireMove: true,
  );
  final d4 = _node(
    fen: _afterD4,
    san: 'd4',
    uci: 'd2d4',
    ply: 1,
    isWhiteToMove: false,
    expectimax: 0.55,
    evalCp: 20,
  );
  final c5 = _node(
    fen: _afterE4C5,
    san: 'c5',
    uci: 'c7c5',
    ply: 2,
    isWhiteToMove: true,
    moveProbability: 0.41,
    expectimax: 0.60,
    evalCp: 25,
  );
  final e5 = _node(
    fen: _afterE4E5,
    san: 'e5',
    uci: 'e7e5',
    ply: 2,
    isWhiteToMove: true,
    moveProbability: 0.30,
    expectimax: 0.65,
    evalCp: 35,
  );
  _link(root, e4);
  _link(root, d4);
  _link(e4, c5);
  _link(e4, e5);
  return BuildTree(
    root: root,
    totalNodes: 5,
    maxPlyReached: 2,
    buildComplete: true,
    startMoves: '',
    configSnapshot: config.toJson(),
  );
}

Widget _pane({
  required String fen,
  BuildTree? tree,
  TreeBuildConfig? config,
  bool compact = true,
}) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 600,
        height: 300,
        child: ExpectimaxLinesPane(
          fen: fen,
          tree: tree,
          config: config,
          isWhiteRepertoire: true,
          boardPreview: BoardPreviewController(),
          compact: compact,
        ),
      ),
    ),
  );
}

void main() {
  const config = TreeBuildConfig(startFen: _startFen, playAsWhite: true);

  testWidgets('on our move: every candidate, best first, chosen starred', (
    tester,
  ) async {
    await tester.pumpWidget(
      _pane(fen: _startFen, tree: _tree(config), config: config),
    );
    await tester.pump();

    expect(find.text('Expectimax · from built tree'), findsOneWidget);
    expect(find.textContaining('OUR CANDIDATES'), findsOneWidget);
    // Both candidates are rows — the pass-over d4 included.
    expect(find.text('1'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.textContaining('e4'), findsWidgets);
    expect(find.textContaining('d4'), findsWidgets);
    // The repertoire pick carries the star.
    expect(find.byIcon(Icons.star), findsOneWidget);
    // Practical and engine columns are both captioned.
    expect(find.text('PRACTICAL'), findsOneWidget);
    expect(find.text('ENGINE'), findsOneWidget);
  });

  testWidgets('on their move: every reply with its likelihood', (tester) async {
    await tester.pumpWidget(
      _pane(fen: _afterE4, tree: _tree(config), config: config),
    );
    await tester.pump();

    expect(find.textContaining('THEIR REPLIES'), findsOneWidget);
    expect(find.textContaining('41%', findRichText: true), findsOneWidget);
    expect(find.textContaining('30%', findRichText: true), findsOneWidget);
  });

  testWidgets('a position the build never reached says so, no spinner', (
    tester,
  ) async {
    await tester.pumpWidget(
      _pane(
        fen: 'rnbqkbnr/pppppppp/8/8/2P5/8/PP1PPPPP/RNBQKBNR b KQkq - 0 1',
        tree: _tree(config),
        config: config,
      ),
    );
    await tester.pump();

    expect(find.text('Not in the built tree'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('a leaf keeps the position value and says the tree ends', (
    tester,
  ) async {
    await tester.pumpWidget(
      _pane(fen: _afterE4C5, tree: _tree(config), config: config),
    );
    await tester.pump();

    expect(find.textContaining('End of the built tree'), findsOneWidget);
    expect(find.textContaining('engine +0.25'), findsOneWidget);
  });

  testWidgets('no tree loaded explains where the values come from', (
    tester,
  ) async {
    await tester.pumpWidget(_pane(fen: _startFen));
    await tester.pump();

    expect(find.text('No built tree loaded'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}

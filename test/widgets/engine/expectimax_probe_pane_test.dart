// The expectimax pane with probe hooks: it offers to compute what the
// database lacks and routes each request to the right position and move.

import 'package:chess_auto_prep/core/board_preview_controller.dart';
import 'package:chess_auto_prep/core/generation_session_controller.dart';
import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/widgets/engine/expectimax_lines_pane.dart';
import 'package:chess_auto_prep/widgets/engine/expectimax_probe_hooks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _startFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
const _afterE4 = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';
const _afterD4 = 'rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq - 0 1';

BuildTreeNode _node(
  String fen,
  String san,
  String uci,
  int ply, {
  required bool whiteToMove,
  required double expectimax,
}) =>
    BuildTreeNode(
        fen: fen,
        moveSan: san,
        moveUci: uci,
        ply: ply,
        isWhiteToMove: whiteToMove,
        nodeId: 0,
      )
      ..engineEvalCp = 20
      ..expectimaxValue = expectimax
      ..hasExpectimax = true;

BuildTree _tree(TreeBuildConfig config) {
  final root = _node(_startFen, '', '', 0, whiteToMove: true, expectimax: 0.6);
  final e4 = _node(
    _afterE4,
    'e4',
    'e2e4',
    1,
    whiteToMove: false,
    expectimax: 0.62,
  );
  final d4 = _node(
    _afterD4,
    'd4',
    'd2d4',
    1,
    whiteToMove: false,
    expectimax: 0.55,
  );
  root.children.addAll([e4, d4]);
  e4.parent = root;
  d4.parent = root;
  return BuildTree(root: root, totalNodes: 3, configSnapshot: config.toJson());
}

class _Recorder {
  final calls = <({String? moveSan, int plies})>[];
  String? error;

  Future<String?> call({String? moveSan, required int plies}) async {
    calls.add((moveSan: moveSan, plies: plies));
    return error;
  }
}

Widget _pane({
  required String fen,
  required ExpectimaxProbeHooks hooks,
  BuildTree? tree,
  TreeBuildConfig? config,
  bool compact = true,
}) => MaterialApp(
  // The app's snackbars set a width, which only floating snackbars allow.
  theme: ThemeData(
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  ),
  home: Scaffold(
    body: SizedBox(
      width: 700,
      height: 320,
      child: ExpectimaxLinesPane(
        fen: fen,
        tree: tree,
        config: config,
        isWhiteRepertoire: true,
        boardPreview: BoardPreviewController(),
        compact: compact,
        hooks: hooks,
      ),
    ),
  ),
);

void main() {
  const config = TreeBuildConfig(startFen: _startFen, playAsWhite: true);
  late GenerationSessionController generation;
  late _Recorder recorder;
  late ExpectimaxProbeHooks hooks;

  setUp(() {
    generation = GenerationSessionController();
    recorder = _Recorder();
    hooks = ExpectimaxProbeHooks(
      generation: generation,
      compute: recorder.call,
    );
  });
  tearDown(() => generation.dispose());

  testWidgets('with no database it offers to compute from here', (
    tester,
  ) async {
    await tester.pumpWidget(_pane(fen: _startFen, hooks: hooks));
    await tester.pump();

    expect(find.text('No expectimax database yet'), findsOneWidget);
    await tester.tap(find.text('Compute from here'));
    await tester.pump();

    expect(recorder.calls, [(moveSan: null, plies: 12)]);
  });

  testWidgets('a position the database lacks gets the same offer', (
    tester,
  ) async {
    await tester.pumpWidget(
      _pane(
        fen: 'rnbqkbnr/pppppppp/8/8/8/5N2/PPPPPPPP/RNBQKB1R b KQkq - 1 1',
        hooks: hooks,
        tree: _tree(config),
        config: config,
      ),
    );
    await tester.pump();

    expect(find.text('Not computed for this position'), findsOneWidget);
    expect(find.text('Compute from here'), findsOneWidget);
  });

  testWidgets('each row can compute the position after its move', (
    tester,
  ) async {
    await tester.pumpWidget(
      _pane(fen: _startFen, hooks: hooks, tree: _tree(config), config: config),
    );
    await tester.pump();

    // One "deeper" control in the header, one per candidate row.
    expect(find.byIcon(Icons.add_circle_outline), findsOneWidget);
    expect(find.byIcon(Icons.play_circle_outline), findsNWidgets(2));

    await tester.tap(find.byIcon(Icons.play_circle_outline).first);
    await tester.pump();
    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await tester.pump();

    // Best candidate first: e4 outranks d4.
    expect(recorder.calls, [
      (moveSan: 'e4', plies: 12),
      (moveSan: null, plies: 12),
    ]);
  });

  testWidgets('a refusal is shown, not swallowed', (tester) async {
    recorder.error = 'A build is running — wait for it to finish first.';
    await tester.pumpWidget(_pane(fen: _startFen, hooks: hooks));
    await tester.pump();

    await tester.tap(find.text('Compute from here'));
    await tester.pump();

    expect(find.textContaining('A build is running'), findsOneWidget);
  });

  testWidgets('read-only without hooks: no compute controls', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 700,
            height: 320,
            child: ExpectimaxLinesPane(
              fen: _startFen,
              tree: _tree(config),
              config: config,
              isWhiteRepertoire: true,
              boardPreview: BoardPreviewController(),
              compact: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byIcon(Icons.add_circle_outline), findsNothing);
    expect(find.byIcon(Icons.play_circle_outline), findsNothing);
  });
}

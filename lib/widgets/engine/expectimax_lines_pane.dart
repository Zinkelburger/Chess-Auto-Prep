/// The expectimax values stored for the current position, laid out as a
/// table: every move the database holds here, what it is worth in practice,
/// what the engine says, and the line that follows.
///
/// Everything shown is read straight from the stored trees — nothing is
/// computed while the user browses, so the pane is instant and never races
/// the engine.  A position the database does not hold says so plainly and,
/// when [ExpectimaxLinesPane.hooks] is given, offers to compute it: a probe
/// is a build the user starts on purpose, runs as a job, and lands back in
/// the database when it finishes — the way a database site queues analysis
/// for a position and shows the result once it is in.
///
/// Visual parity with [UnifiedEnginePane]: rank, eval, clickable/hoverable
/// SAN continuation.
library;

import 'package:flutter/material.dart';

import 'dart:async';

import '../../models/build_tree_node.dart';
import 'package:chess_auto_prep/core/board_preview_controller.dart';
import '../../models/eval_database_settings.dart';
import '../../services/coherence_service.dart';
import '../../services/expectimax_line_service.dart';
import '../../services/generation/eca_calculator.dart';
import '../../services/generation/fen_map.dart';
import '../../services/generation/generation_config.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import '../../utils/chess_utils.dart' show fenAfterMoves, formatPackedEval;
import '../../utils/app_messages.dart';
import '../../utils/ease_utils.dart' show expectedCpFromWinProb;
import '../clickable_move_line.dart';
import 'expectimax_probe_hooks.dart';
import 'floating_board_preview.dart';
import '../../utils/fen_utils.dart';

/// Depths the pane offers for a probe, in half-moves.
const List<int> kExpectimaxProbePlyChoices = [6, 8, 10, 12, 16, 20, 24];

class ExpectimaxLinesPane extends StatefulWidget {
  final String fen;
  final BuildTree? tree;
  final TreeBuildConfig? config;
  final FenMap? fenMap;
  final bool isWhiteRepertoire;
  final BoardPreviewController boardPreview;
  final void Function(String san)? onMoveSelected;
  final void Function(List<String> sanMoves, int index)? onLineMoveClicked;
  final CoherenceResult? coherenceResult;

  /// Embedded beside the engine pane — no bottom line-length control.
  final bool compact;

  /// Lets the user ask for values the database lacks. Null: read-only.
  final ExpectimaxProbeHooks? hooks;

  const ExpectimaxLinesPane({
    super.key,
    required this.fen,
    this.tree,
    this.config,
    this.fenMap,
    required this.isWhiteRepertoire,
    required this.boardPreview,
    this.onMoveSelected,
    this.onLineMoveClicked,
    this.coherenceResult,
    this.compact = false,
    this.hooks,
  });

  @override
  State<ExpectimaxLinesPane> createState() => _ExpectimaxLinesPaneState();
}

class _ExpectimaxLinesPaneState extends State<ExpectimaxLinesPane> {
  List<ExpectimaxLine> _lines = [];

  /// The tree node for [ExpectimaxLinesPane.fen], or null when the build
  /// never reached this position.
  BuildTreeNode? _node;
  int _maxPlies = 12;
  final GlobalKey _previewStackKey = GlobalKey();

  /// Half-moves the next probe explores; remembered across sessions.
  int _probePlies = EvalDatabaseSettings.instance.expectimaxProbePlies;

  @override
  void initState() {
    super.initState();
    if (!kExpectimaxProbePlyChoices.contains(_probePlies)) {
      _probePlies = EvalDatabaseSettings.defaultExpectimaxProbePlies;
    }
    _recompute();
  }

  @override
  void didUpdateWidget(covariant ExpectimaxLinesPane old) {
    super.didUpdateWidget(old);
    if (old.fen != widget.fen ||
        old.tree != widget.tree ||
        old.config != widget.config ||
        old.fenMap != widget.fenMap) {
      _recompute();
    }
  }

  /// Look the position up and list every move the tree holds there.  A
  /// transposition leaf resolves to the node that carries the subtree, so a
  /// position reached by another move order still shows its values.
  void _recompute() {
    final tree = widget.tree;
    final config = widget.config;
    if (tree == null || config == null) {
      _node = null;
      _lines = [];
      return;
    }

    var node = widget.fenMap?.getCanonical(widget.fen);
    if (node == null || node.children.isEmpty) {
      node = findNodeByFen(tree, widget.fen) ?? node;
    }
    _node = node;
    if (node == null) {
      _lines = [];
      return;
    }

    final eca = ExpectimaxCalculator(config: config, fenMap: widget.fenMap);
    _lines = expectimaxLinesForAllMoves(
      node,
      config,
      eca,
      maxPlies: _maxPlies,
      fenMap: widget.fenMap,
    );
  }

  int get _startPly => plyFromFen(widget.fen);

  bool get _isOurMove {
    final config = widget.config;
    final node = _node;
    if (config == null || node == null) return false;
    return node.isWhiteToMove == config.playAsWhite;
  }

  // ── Probes ───────────────────────────────────────────────────────────

  Future<void> _startProbe({String? moveSan}) async {
    final hooks = widget.hooks;
    if (hooks == null) return;
    final error = await hooks.compute(moveSan: moveSan, plies: _probePlies);
    if (error != null && mounted) {
      showAppSnackBar(context, error, isError: true);
    }
  }

  void _setProbePlies(int? plies) {
    if (plies == null) return;
    setState(() => _probePlies = plies);
    unawaited(EvalDatabaseSettings.instance.setExpectimaxProbePlies(plies));
  }

  /// Compute button plus depth picker, or the run state while one is in
  /// flight. Empty when the pane is read-only.
  Widget? _probeActions({String? moveSan, String? label}) {
    final hooks = widget.hooks;
    if (hooks == null) return null;
    if (hooks.isBusy) return _probeRunning(hooks);
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Tooltip(
          message:
              'Runs a small build from this position — engine, Maia and any '
              'evaluation database you have enabled — and stores the result. '
              'Runs as a job; keep browsing meanwhile.',
          child: FilledButton.tonalIcon(
            onPressed: () => unawaited(_startProbe(moveSan: moveSan)),
            icon: const Icon(Icons.functions, size: 16),
            label: Text(
              label ?? 'Compute from here',
              style: const TextStyle(fontSize: 12),
            ),
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 10),
            ),
          ),
        ),
        _probeDepthPicker(),
      ],
    );
  }

  Widget _probeDepthPicker() {
    return Tooltip(
      message: 'How many half-moves a probe explores below its position.',
      child: DropdownButton<int>(
        value: _probePlies,
        isDense: true,
        underline: const SizedBox.shrink(),
        style: AppTextStyles.caption,
        items: [
          for (final plies in kExpectimaxProbePlyChoices)
            DropdownMenuItem(value: plies, child: Text('$plies half-moves')),
        ],
        onChanged: _setProbePlies,
      ),
    );
  }

  Widget _probeRunning(ExpectimaxProbeHooks hooks) {
    if (!hooks.isProbeRunning) {
      return const Text(
        'A build is running — probes can start once it finishes.',
        style: AppTextStyles.caption,
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            hooks.status.isEmpty ? 'Computing…' : hooks.status,
            style: AppTextStyles.caption,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        TextButton(
          onPressed: hooks.cancel,
          style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
          child: const Text('Cancel', style: TextStyle(fontSize: 12)),
        ),
      ],
    );
  }

  /// Header-corner control: a "deeper" button when idle, the run state
  /// while a probe is in flight.
  Widget? _headerProbeControl() {
    final hooks = widget.hooks;
    if (hooks == null) return null;
    if (hooks.isBusy) {
      if (!hooks.isProbeRunning) return null;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 6),
          const Text('Computing…', style: AppTextStyles.caption),
          IconButton(
            tooltip: 'Cancel the probe',
            icon: const Icon(Icons.close, size: 14),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
            onPressed: hooks.cancel,
          ),
        ],
      );
    }
    return IconButton(
      tooltip:
          'Compute $_probePlies half-moves deeper from here and add the '
          'result to the database',
      icon: const Icon(Icons.add_circle_outline, size: 16),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
      onPressed: () => unawaited(_startProbe()),
    );
  }

  /// Per-row control: compute the position after this row's first move.
  Widget? _rowProbeControl(ExpectimaxLine line) {
    final hooks = widget.hooks;
    if (hooks == null || hooks.isBusy || line.movesSan.isEmpty) return null;
    final san = line.movesSan.first;
    return IconButton(
      tooltip: 'Compute $_probePlies half-moves after $san',
      icon: const Icon(Icons.play_circle_outline, size: 15),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
      onPressed: () => unawaited(_startProbe(moveSan: san)),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.tree == null || widget.config == null) {
      return _buildEmptyState(
        icon: Icons.analytics_outlined,
        title: 'No expectimax database yet',
        body: widget.hooks != null
            ? 'Generate a repertoire, or compute expectimax from this '
                  'position to start one.'
            : 'Expectimax values are computed when a repertoire is generated. '
                  'Generate or open one to see them here.',
        actions: _probeActions(),
      );
    }
    final node = _node;
    if (node == null) {
      return _buildEmptyState(
        icon: Icons.search_off,
        title: 'Not computed for this position',
        body: widget.hooks != null
            ? 'No build has reached this position. Compute from here to add '
                  'it to the database.'
            : 'The build never reached this position, so it has no expectimax '
                  'value. Step back into the repertoire to see the values again.',
        actions: _probeActions(),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildHeader(node),
        const Divider(height: 1),
        Expanded(
          child: _lines.isEmpty
              ? _buildLeafState()
              : Stack(
                  key: _previewStackKey,
                  clipBehavior: Clip.none,
                  children: [
                    ListView.builder(
                      itemCount: _lines.length + 1,
                      itemBuilder: (ctx, i) => i == 0
                          ? _buildColumnHeadings()
                          : _buildLineRow(_lines[i - 1]),
                    ),
                    FloatingBoardPreview(
                      stackKey: _previewStackKey,
                      controller: widget.boardPreview,
                      flipped: !widget.isWhiteRepertoire,
                      ownerTag: _previewStackKey,
                    ),
                  ],
                ),
        ),
        if (!widget.compact) _buildControls(),
      ],
    );
  }

  Widget _buildEmptyState({
    required IconData icon,
    required String title,
    required String body,
    Widget? actions,
  }) {
    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 28, color: AppColors.onSurfaceDim),
              const SizedBox(height: 8),
              Text(
                title,
                style: const TextStyle(
                  color: AppColors.onSurfaceSoft,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                body,
                style: const TextStyle(
                  color: AppColors.onSurfaceMuted,
                  fontSize: 12,
                  height: 1.3,
                ),
                textAlign: TextAlign.center,
              ),
              if (actions != null) ...[const SizedBox(height: 10), actions],
            ],
          ),
        ),
      ),
    );
  }

  /// In the tree, but the build stopped here: the header still carries the
  /// position's own value, so say only that there is nothing below it.
  Widget _buildLeafState() {
    final actions = _probeActions();
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'End of the stored tree — no continuations were explored from '
            'here.',
            style: TextStyle(color: AppColors.onSurfaceMuted, fontSize: 12),
          ),
          if (actions != null) ...[const SizedBox(height: 8), actions],
        ],
      ),
    );
  }

  /// "Expectimax · from built tree" plus the position's own value beside the
  /// engine's, so the reader sees at once how much practical edge the
  /// repertoire expects over what the board objectively offers.
  Widget _buildHeader(BuildTreeNode node) {
    final playAsWhite = widget.config!.playAsWhite;
    final practical = node.hasExpectimax
        ? _formatEval(expectedCpFromWinProb(node.expectimaxValue))
        : null;
    final engine = node.hasEngineEval
        ? _formatEval(node.evalForUs(playAsWhite))
        : null;

    final probeControl = _headerProbeControl();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          const Flexible(
            child: Tooltip(
              message:
                  'What each move is worth in practice, from the stored '
                  'trees.\n'
                  'Expectimax folds Stockfish evals with how often humans\n'
                  '(Maia at the build rating) actually go wrong, so a move\n'
                  'that sets problems scores above its raw eval.\n\n'
                  'Values are stored when a build or a probe runs — nothing\n'
                  'is computed while you browse.',
              child: Text(
                'Expectimax database',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (practical != null)
            Tooltip(
              message: engine != null
                  ? 'This position: $practical in practice, '
                        '$engine by the engine.'
                  : 'This position: $practical in practice.',
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    practical,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      fontFamily: AppTextStyles.monoFamily,
                      color: AppColors.cpEval(
                        expectedCpFromWinProb(node.expectimaxValue),
                      ),
                    ),
                  ),
                  if (engine != null)
                    Text(
                      '  engine $engine',
                      style: const TextStyle(
                        fontSize: 12,
                        fontFamily: AppTextStyles.monoFamily,
                        color: AppColors.onSurfaceMuted,
                      ),
                    ),
                ],
              ),
            ),
          if (probeControl != null) ...[const Spacer(), probeControl],
        ],
      ),
    );
  }

  /// Column captions.  The table reads differently on the two kinds of
  /// position — our candidates ranked by value, or their replies ranked by
  /// how likely they are — and the caption row says which one this is.
  Widget _buildColumnHeadings() {
    const style = TextStyle(
      fontSize: 12,
      color: AppColors.onSurfaceMuted,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.3,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 2),
      child: Row(
        children: [
          const SizedBox(width: 20),
          const Tooltip(
            message:
                'Expected eval after the move, counting how often opponents '
                'go wrong from there.',
            child: SizedBox(width: 56, child: Text('PRACTICAL', style: style)),
          ),
          const Tooltip(
            message: 'Raw Stockfish eval after the move, for comparison.',
            child: SizedBox(width: 48, child: Text('ENGINE', style: style)),
          ),
          if (widget.coherenceResult != null) const SizedBox(width: 40),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _isOurMove
                  ? 'OUR CANDIDATES · best value first · ★ chosen'
                  : 'THEIR REPLIES · most likely first',
              style: style,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLineRow(ExpectimaxLine line) {
    final practical = _formatEval(line.expectedEvalCp);
    final engine = line.evalCp != null ? _formatEval(line.evalCp!) : '—';
    final first = line.moveInfo.isNotEmpty ? line.moveInfo.first : null;
    final isChosen = first != null && first.isOurMove && first.isRepertoireMove;

    final annotations = <MoveAnnotation>[];
    for (final info in line.moveInfo) {
      if (!info.isOurMove && info.moveProbability > 0) {
        final pct = (info.moveProbability * 100).round();
        annotations.add(
          MoveAnnotation(
            suffix: ' $pct%',
            suffixColor: pct >= 50
                ? AppColors.warning
                : AppColors.onSurfaceMuted,
            suffixFontWeight: FontWeight.w600,
          ),
        );
      } else if (info.isOurMove && info.isRepertoireMove) {
        annotations.add(
          const MoveAnnotation(
            prefixIcon: Icons.star,
            prefixIconColor: AppColors.expectimax,
            iconSize: 9,
          ),
        );
      } else {
        annotations.add(const MoveAnnotation());
      }
    }

    double? coherence;
    if (widget.coherenceResult != null) {
      coherence = _averageCoherenceForFirstMove(
        line.movesSan.isNotEmpty ? line.movesSan.first : null,
      );
    }

    return Container(
      color: isChosen ? AppColors.expectimax.withValues(alpha: 0.08) : null,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 20,
            child: Text(
              '${line.rank}',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
          ),
          Tooltip(
            message: line.evalCp != null
                ? 'Practical $practical · engine $engine'
                : 'Practical $practical',
            child: SizedBox(
              width: 56,
              child: Text(
                practical,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  fontFamily: AppTextStyles.monoFamily,
                  color: AppColors.cpEval(line.expectedEvalCp),
                ),
              ),
            ),
          ),
          SizedBox(
            width: 48,
            child: Text(
              engine,
              style: const TextStyle(
                fontSize: 12,
                fontFamily: AppTextStyles.monoFamily,
                color: AppColors.onSurfaceMuted,
              ),
            ),
          ),
          if (coherence != null)
            Tooltip(
              message:
                  'Coherence: lines through this move share '
                  '${(coherence * 100).round()}% structural patterns',
              child: Container(
                width: 40,
                padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                child: Text(
                  'C:${(coherence * 100).round()}',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.coherence(coherence),
                    fontFamily: AppTextStyles.monoFamily,
                  ),
                ),
              ),
            ),
          const SizedBox(width: 6),
          Expanded(
            child: ClickableMoveLineWidget(
              sanMoves: line.movesSan,
              startPly: _startPly,
              maxMoves: 10,
              maxLines: 1,
              annotations: annotations,
              onMoveTapped: (idx) => _onLineMoveTapped(line, idx),
              onMoveHovered: (idx, pos) => _onMoveHovered(line, idx, pos),
              onHoverExit: () => widget.boardPreview.clearPreview(),
            ),
          ),
          ?_rowProbeControl(line),
        ],
      ),
    );
  }

  double? _averageCoherenceForFirstMove(String? firstMoveSan) {
    if (firstMoveSan == null || widget.coherenceResult == null) return null;
    final scores = widget.coherenceResult!.lineCoherenceById;
    if (scores.isEmpty) return null;
    final values = scores.values.toList();
    return values.reduce((a, b) => a + b) / values.length;
  }

  Widget _buildControls() {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        children: [
          if (widget.hooks != null) ...[
            const Text('Probe depth ', style: AppTextStyles.caption),
            _probeDepthPicker(),
          ],
          const Spacer(),
          Tooltip(
            message: 'How far each line continues past the current position',
            child: DropdownButton<int>(
              value: _maxPlies,
              items: [4, 8, 12, 16, 20]
                  .map(
                    (v) => DropdownMenuItem(
                      value: v,
                      child: Text('+$v half-moves'),
                    ),
                  )
                  .toList(),
              onChanged: (v) {
                if (v != null) {
                  setState(() {
                    _maxPlies = v;
                    _recompute();
                  });
                }
              },
              isDense: true,
              underline: const SizedBox.shrink(),
            ),
          ),
        ],
      ),
    );
  }

  void _onLineMoveTapped(ExpectimaxLine line, int index) {
    widget.onLineMoveClicked?.call(line.movesSan, index);
  }

  void _onMoveHovered(ExpectimaxLine line, int index, Offset anchorGlobal) {
    final fen = fenAfterMoves(widget.fen, line.movesSan, index);
    final uci = index < line.movesUci.length ? line.movesUci[index] : null;
    widget.boardPreview.setPreview(
      fen,
      moves: line.movesSan.sublist(0, index + 1),
      target: BoardPreviewTarget.floating,
      lastMoveUci: uci,
      anchorGlobal: anchorGlobal,
      ownerTag: _previewStackKey,
    );
  }

  static String _formatEval(int cp) => formatPackedEval(cp, decimals: 2);
}

/// The expectimax values a build stored for the current position, laid out
/// as a table: every move the tree holds here, what it is worth in practice,
/// what the engine says, and the line that follows.
///
/// Everything shown is read straight from the built tree — nothing is
/// computed while the user browses, so the pane is instant and never races
/// the engine.  A position the build did not reach says so plainly instead
/// of spinning.
///
/// Visual parity with [UnifiedEnginePane]: rank, eval, clickable/hoverable
/// SAN continuation.
library;

import 'package:flutter/material.dart';

import '../../models/build_tree_node.dart';
import 'package:chess_auto_prep/core/board_preview_controller.dart';
import '../../services/coherence_service.dart';
import '../../services/expectimax_line_service.dart';
import '../../services/generation/eca_calculator.dart';
import '../../services/generation/fen_map.dart';
import '../../services/generation/generation_config.dart';
import '../../theme/app_colors.dart';
import '../../utils/chess_utils.dart' show fenAfterMoves, formatPackedEval;
import '../../utils/ease_utils.dart' show expectedCpFromWinProb;
import '../clickable_move_line.dart';
import 'floating_board_preview.dart';
import '../../utils/fen_utils.dart';

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

  @override
  void initState() {
    super.initState();
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

  @override
  Widget build(BuildContext context) {
    if (widget.tree == null || widget.config == null) {
      return _buildEmptyState(
        icon: Icons.analytics_outlined,
        title: 'No built tree loaded',
        body:
            'Expectimax values are computed when a repertoire is generated. '
            'Generate or open one to see them here.',
      );
    }
    final node = _node;
    if (node == null) {
      return _buildEmptyState(
        icon: Icons.search_off,
        title: 'Not in the built tree',
        body:
            'The build never reached this position, so it has no expectimax '
            'value. Step back into the repertoire to see the values again.',
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
  }) {
    return Center(
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
                fontSize: 11,
                height: 1.3,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  /// In the tree, but the build stopped here: the header still carries the
  /// position's own value, so say only that there is nothing below it.
  Widget _buildLeafState() {
    return const Padding(
      padding: EdgeInsets.all(12),
      child: Text(
        'End of the built tree — no continuations were explored from here.',
        style: TextStyle(color: AppColors.onSurfaceMuted, fontSize: 11),
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

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          const Flexible(
            child: Tooltip(
              message:
                  'What each move is worth in practice, from the built tree.\n'
                  'Expectimax folds Stockfish evals with how often humans\n'
                  '(Maia at the build rating) actually go wrong, so a move\n'
                  'that sets problems scores above its raw eval.\n\n'
                  'Values are stored at build time — nothing is computed\n'
                  'while you browse.',
              child: Text(
                'Expectimax · from built tree',
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
                      fontFamily: 'monospace',
                      color: AppColors.cpEval(
                        expectedCpFromWinProb(node.expectimaxValue),
                      ),
                    ),
                  ),
                  if (engine != null)
                    Text(
                      '  engine $engine',
                      style: const TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: AppColors.onSurfaceMuted,
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// Column captions.  The table reads differently on the two kinds of
  /// position — our candidates ranked by value, or their replies ranked by
  /// how likely they are — and the caption row says which one this is.
  Widget _buildColumnHeadings() {
    const style = TextStyle(
      fontSize: 10,
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
                  fontFamily: 'monospace',
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
                fontSize: 11,
                fontFamily: 'monospace',
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
                    fontSize: 10,
                    color: AppColors.coherence(coherence),
                    fontFamily: 'monospace',
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

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:chess_auto_prep/core/board_preview_controller.dart';
import '../../../utils/app_shortcuts.dart';
import '../models/tactics_note.dart';
import '../models/tactics_position.dart';
import '../services/tactics_engine.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../utils/chess_utils.dart' show fenAfterMoves, sanToUci;
import '../../../widgets/clickable_move_line.dart';
import '../../../widgets/engine/floating_board_preview.dart';
import '../../../widgets/labeled_toggle.dart';
import '../../../widgets/shortcut_tooltip.dart';

/// Puzzle-solving controls shown during an active tactics session.
class TacticsTrainingPanel extends StatefulWidget {
  const TacticsTrainingPanel({
    super.key,
    required this.position,
    required this.engine,
    required this.currentMoveIndex,
    required this.positionSolved,
    required this.showSolution,
    required this.isAtStartingPosition,
    required this.feedback,
    required this.autoAdvance,
    required this.onToggleSolution,
    required this.onAnalyze,
    required this.onResetAnalysis,
    this.onPreviousPosition,
    this.onSkipPosition,
    this.isLastSessionPuzzle = false,
    required this.onAutoAdvanceChanged,
    required this.onCopyFen,
    this.onEdit,
    required this.onSetRating,
    this.solutionSanMoves = const [],
    this.solutionStartPly = 0,
    this.activeSolutionMoveIndex,
    this.onSolutionMoveTapped,
    this.previewFlipped = false,
  });

  final TacticsPosition position;
  final TacticsEngine engine;
  final int currentMoveIndex;
  final bool positionSolved;
  final bool showSolution;
  final bool isAtStartingPosition;
  final String feedback;
  final bool autoAdvance;
  final VoidCallback onToggleSolution;
  final VoidCallback onAnalyze;
  final VoidCallback onResetAnalysis;

  /// Null grays the button out — the first puzzle has no "previous".
  final VoidCallback? onPreviousPosition;

  /// Null grays the button out — the last item of a browse walk has no
  /// "next". (In a session Next stays live on the last puzzle; it finishes
  /// the session, see [isLastSessionPuzzle].)
  final VoidCallback? onSkipPosition;

  /// Relabels Skip/Next to "Finish": pressing it ends the session and shows
  /// the recap instead of loading another puzzle.
  final bool isLastSessionPuzzle;
  final ValueChanged<bool> onAutoAdvanceChanged;
  final VoidCallback onCopyFen;

  /// Opens the edit dialog for this tactic. Hidden when null (external sets,
  /// or the unsolved head of a session where editing would reveal the answer).
  final VoidCallback? onEdit;
  final ValueChanged<int> onSetRating;
  final List<String> solutionSanMoves;
  final int solutionStartPly;
  final int? activeSolutionMoveIndex;
  final void Function(List<String> sanMoves, int clickedIndex)?
  onSolutionMoveTapped;

  /// Orientation of the floating hover-preview board (matches the main board).
  final bool previewFlipped;

  @override
  State<TacticsTrainingPanel> createState() => _TacticsTrainingPanelState();
}

class _TacticsTrainingPanelState extends State<TacticsTrainingPanel> {
  /// Drives the floating mini-board shown when hovering solution-line moves —
  /// the same preview mechanism as the engine bar's PV hover.
  final BoardPreviewController _boardPreview = BoardPreviewController();
  final GlobalKey _previewKey = GlobalKey();

  @override
  void dispose() {
    _boardPreview.dispose();
    super.dispose();
  }

  bool get _showRating =>
      !widget.autoAdvance && (widget.positionSolved || widget.showSolution);

  bool get _useNextLabel => widget.positionSolved || widget.showSolution;

  String get _nextLabel {
    if (widget.isLastSessionPuzzle) return 'Finish';
    return _useNextLabel ? 'Next' : 'Skip';
  }

  String get _nextDescription {
    if (widget.onSkipPosition == null) return 'Already at the last position';
    if (widget.isLastSessionPuzzle) return 'Finish the session';
    return _useNextLabel ? 'Next position' : 'Skip position';
  }

  /// Everything that would give the tactic away is shown once the puzzle is
  /// solved or the solution is asked for.
  bool get _isRevealed => widget.positionSolved || widget.showSolution;

  /// The solution line to print: the whole thing once revealed, otherwise
  /// just the moves found so far — so a multi-move puzzle shows where you are.
  List<String> get _visibleSolution {
    final san = widget.solutionSanMoves;
    if (_isRevealed) return san;
    final found = widget.currentMoveIndex.clamp(0, san.length);
    return san.sublist(0, found);
  }

  @override
  Widget build(BuildContext context) {
    final solution = _visibleSolution;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TacticsPositionInfo(
          position: widget.position,
          engine: widget.engine,
          onEdit: widget.onEdit,
          onCopyFen: widget.onCopyFen,
          revealed: _isRevealed,
        ),
        const SizedBox(height: 10),
        // Feedback keeps a fixed slot so the rest of the panel never jumps
        // when it appears.
        SizedBox(
          height: 24,
          child: Text(
            widget.feedback,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(height: 4),
        // One line for the solution: fills in move by move while solving,
        // complete as soon as the puzzle is over — no button to press.
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 28),
          child: solution.isEmpty && !_isRevealed
              ? const SizedBox.shrink()
              : _buildSolutionLine(context, solution),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            // Once solved, the solution is already on screen.
            if (!widget.positionSolved) ...[
              Expanded(
                child: shortcutTooltip(
                  description: widget.showSolution
                      ? 'Hide solution'
                      : 'Show solution',
                  shortcut: AppShortcut.toggleSolution,
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: widget.onToggleSolution,
                      child: Text(
                        widget.showSolution ? 'Hide Solution' : 'Show Solution',
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: widget.isAtStartingPosition
                  ? shortcutTooltip(
                      description: 'Analyze',
                      // V only: A is the a-file, and the move box is always
                      // hot while solving, so an A binding can never fire.
                      shortcut: AppShortcut.analyzePosition,
                      child: SizedBox(
                        width: double.infinity,
                        child: OutlinedButton(
                          onPressed: widget.onAnalyze,
                          child: const Text('Analyze'),
                        ),
                      ),
                    )
                  : Tooltip(
                      message: 'Reset analysis',
                      child: SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: widget.onResetAnalysis,
                          icon: const Icon(Icons.refresh, size: 16),
                          label: const Text('Reset'),
                        ),
                      ),
                    ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: shortcutTooltip(
                description: widget.onPreviousPosition != null
                    ? 'Previous position'
                    : 'Already at the first position',
                shortcut: AppShortcut.previousItem,
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: widget.onPreviousPosition,
                    child: const Text('Previous'),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: shortcutTooltip(
                description: _nextDescription,
                shortcut: AppShortcut.nextItem,
                child: SizedBox(
                  width: double.infinity,
                  child: _isRevealed
                      ? ElevatedButton(
                          onPressed: widget.onSkipPosition,
                          child: Text(_nextLabel),
                        )
                      : OutlinedButton(
                          onPressed: widget.onSkipPosition,
                          child: Text(_nextLabel),
                        ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        ShortcutTooltip(
          description: 'Toggle auto-advance to next position',
          shortcut: AppShortcut.autoAdvance,
          child: AppSwitch(
            label: 'Auto-advance to next position',
            value: widget.autoAdvance,
            onChanged: widget.onAutoAdvanceChanged,
          ),
        ),
        if (_showRating) ...[
          const SizedBox(height: 8),
          _TacticsStarRating(
            rating: widget.position.rating,
            onSetRating: widget.onSetRating,
          ),
        ],
        // Renders nothing inline; drives the hover mini-board via Overlay.
        FloatingBoardPreview(
          stackKey: _previewKey,
          controller: _boardPreview,
          flipped: widget.previewFlipped,
          ownerTag: _previewKey,
        ),
      ],
    );
  }

  /// Show the floating board after [sanMoves] up to and including [idx],
  /// replayed from the tactic's starting position.
  void _showPreview(List<String> sanMoves, int idx, Offset anchor) {
    if (sanMoves.isEmpty) return;
    final startFen = widget.position.fen;
    final beforeFen = idx == 0
        ? startFen
        : fenAfterMoves(startFen, sanMoves, idx - 1);
    _boardPreview.setPreview(
      fenAfterMoves(startFen, sanMoves, idx),
      moves: sanMoves.sublist(0, idx + 1),
      target: BoardPreviewTarget.floating,
      lastMoveUci: sanToUci(beforeFen, sanMoves[idx]),
      anchorGlobal: anchor,
      ownerTag: _previewKey,
    );
  }

  /// The best move's eval, shown next to the move it belongs to (`Qf3 +0.5`)
  /// rather than restated in the note box above.
  ///
  /// Only the first move is annotated: it is the one the engine scored. The
  /// rest of the line is its principal variation, never evaluated ply by ply,
  /// so a number beside those moves would be made up.
  List<MoveAnnotation>? _bestMoveEvalAnnotation(List<String> san) {
    if (san.isEmpty) return null;
    final parts = TacticsNote.parse(widget.position.mistakeAnalysis);
    if (parts == null || parts.evalBest.isEmpty) return null;
    // A note whose best move isn't the line being shown belongs to a different
    // solution (an edited or custom puzzle) — better no eval than a wrong one.
    if (parts.bestSan.isNotEmpty && parts.bestSan != san.first) return null;
    return [
      MoveAnnotation(
        suffix: ' ${parts.evalBest}',
        suffixColor: AppColors.onSurfaceMuted,
      ),
    ];
  }

  Widget _buildSolutionLine(BuildContext context, List<String> san) {
    final Widget line;
    if (san.isEmpty) {
      final fallback = widget.engine.getSolution(widget.position, fromIndex: 0);
      line = Text(
        fallback,
        style: fallback == 'No solution available'
            ? AppTextStyles.muted
            : AppTextStyles.mono,
      );
    } else {
      final trainablePlies = widget.position.correctLine.length;
      // While solving there is nothing to point at; once revealed, the move
      // the board is parked on.
      final highlightIndex = !_isRevealed
          ? null
          : widget.activeSolutionMoveIndex ??
                (widget.currentMoveIndex < trainablePlies
                    ? widget.currentMoveIndex
                    : null);
      line = ClickableMoveLineWidget(
        key: const Key('tactic-solution-line'),
        sanMoves: san,
        startPly: widget.solutionStartPly,
        annotations: _isRevealed ? _bestMoveEvalAnnotation(san) : null,
        maxMoves: san.length,
        singleLine: false,
        fontSize: 14,
        movePadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        activeMoveIndex: highlightIndex,
        // Walking the board along the line is only for a finished puzzle.
        onMoveTapped: _isRevealed && widget.onSolutionMoveTapped != null
            ? (idx) => widget.onSolutionMoveTapped!(san, idx)
            : null,
        onMoveHovered: (idx, anchor) => _showPreview(san, idx, anchor),
        onHoverExit: _boardPreview.clearPreview,
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 3, right: 8),
          child: Text(
            'Solution',
            style: TextStyle(fontSize: 13, color: AppColors.onSurfaceSoft),
          ),
        ),
        Expanded(child: line),
      ],
    );
  }
}

/// Compact 1-5 star rating row for tactic quality.
class _TacticsStarRating extends StatelessWidget {
  const _TacticsStarRating({required this.rating, required this.onSetRating});

  final int rating;
  final ValueChanged<int> onSetRating;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Text(
          'Rate:',
          style: TextStyle(fontSize: 13, color: AppColors.onSurfaceSoft),
        ),
        const SizedBox(width: 8),
        for (int star = 1; star <= 5; star++)
          Tooltip(
            message: 'Rate $star star${star > 1 ? 's' : ''}',
            child: GestureDetector(
              onTap: () => onSetRating(rating == star ? 0 : star),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Icon(
                  star <= rating ? Icons.star : Icons.star_border,
                  size: 24,
                  color: star <= rating
                      ? AppColors.starAccent
                      : AppColors.starEmpty,
                ),
              ),
            ),
          ),
        if (rating > 0)
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Text(
              rating == 1 ? '(hidden from training)' : '',
              style: const TextStyle(
                fontSize: 11,
                color: AppColors.onSurfaceMuted,
              ),
            ),
          ),
      ],
    );
  }
}

/// The top of the panel: the task, where the position came from, and the
/// game line — what was played and, once revealed, what it allowed.
class TacticsPositionInfo extends StatelessWidget {
  const TacticsPositionInfo({
    super.key,
    required this.position,
    required this.engine,
    this.onEdit,
    this.onCopyFen,
    this.revealed = false,
  });

  final TacticsPosition position;
  final TacticsEngine engine;

  /// Opens the edit dialog for this tactic. Hidden when null.
  final VoidCallback? onEdit;

  /// Copies the puzzle FEN. Hidden when null.
  final VoidCallback? onCopyFen;

  /// Whether the answer is out: adds the refutation and the eval to the
  /// game line.
  final bool revealed;

  @override
  Widget build(BuildContext context) {
    final pos = position;
    final moveCount = math.max(1, engine.userMoveCount(pos));
    final side = pos.whiteToPlay ? 'White' : 'Black';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                moveCount > 1
                    ? '$side to play · $moveCount moves'
                    : '$side to play',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
            ),
            if (onCopyFen != null)
              IconButton(
                onPressed: onCopyFen,
                icon: const Icon(Icons.content_copy, size: 15),
                tooltip: 'Copy FEN',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                padding: EdgeInsets.zero,
              ),
            if (onEdit != null)
              IconButton(
                onPressed: onEdit,
                icon: const Icon(Icons.edit, size: 16),
                tooltip: 'Edit this tactic',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                padding: EdgeInsets.zero,
              ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          pos.provenanceLine,
          style: const TextStyle(fontSize: 13, color: AppColors.onSurfaceSoft),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 8),
        // Always the same height whether or not the puzzle records a played
        // move, so the buttons below never shift on Next.
        Visibility(
          visible: pos.userMove.isNotEmpty,
          maintainSize: true,
          maintainAnimation: true,
          maintainState: true,
          child: _GameLine(position: pos, revealed: revealed),
        ),
      ],
    );
  }
}

/// "You played h5 (blunder)." — and once the answer is out, what it allowed
/// and what it cost on the same line: "You played h5 (blunder), allowing
/// Nxe5.  +0.5 → -2.1". Plain prose; the moves are bold and nothing else is.
class _GameLine extends StatelessWidget {
  const _GameLine({required this.position, required this.revealed});

  final TacticsPosition position;
  final bool revealed;

  @override
  Widget build(BuildContext context) {
    const base = TextStyle(fontSize: 14, color: AppColors.ink, height: 1.4);
    const move = TextStyle(fontWeight: FontWeight.bold);
    const soft = TextStyle(color: AppColors.onSurfaceSoft);

    final severity = position.mistakeLabel;
    final note = TacticsNote.parse(position.mistakeAnalysis);
    final refutation = position.opponentBestResponse;

    final spans = <TextSpan>[
      const TextSpan(text: 'You played '),
      TextSpan(text: position.userMove, style: move),
      // The one coloured word on the line: blue / amber / red mean
      // inaccuracy / mistake / blunder everywhere else in chess too.
      if (severity.isNotEmpty)
        TextSpan(
          text: ' ($severity)',
          style: TextStyle(color: _severityColor(position.mistakeType)),
        ),
    ];
    if (revealed && refutation.isNotEmpty) {
      spans.addAll([
        const TextSpan(text: ', allowing '),
        TextSpan(text: refutation, style: move),
      ]);
    }
    spans.add(const TextSpan(text: '.'));
    if (revealed && note != null) {
      spans.add(
        TextSpan(text: '  ${note.evalBefore} → ${note.evalAfter}', style: soft),
      );
    }

    return Text.rich(
      TextSpan(style: base, children: spans),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }

  static Color _severityColor(String mistakeType) => switch (mistakeType) {
    '??' => AppColors.mistakeBlunder,
    '?' => AppColors.mistakeMistake,
    '?!' => AppColors.mistakeInaccuracy,
    _ => AppColors.ink,
  };
}

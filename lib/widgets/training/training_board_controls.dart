import 'package:chess_auto_prep/chess_core/pgn/pgn_game_view.dart';
import 'package:chess_auto_prep/chess_core/pgn/pgn_parser.dart';
import 'package:dartchess/dartchess.dart' show PgnNodeData, Side;
import 'package:flutter/material.dart';

import '../../features/repertoires/controllers/repertoire_board_controller.dart';
import '../../models/repertoire_line.dart';
import '../../features/training/models/training_phase.dart';
import '../../features/training/controllers/training_session_controller.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import '../pgn/pgn_text_styles.dart';
import '../pgn/pgn_movetext_view.dart';
import '../../utils/app_shortcuts.dart';
import '../../utils/pgn_comment_utils.dart' show filterDisplayComment;
import '../chess_board_widget.dart';
import '../shortcut_tooltip.dart';
import 'move_input_widget.dart';

/// Chess board area for the trainer.
///
/// Used for active training (learn / drill / replay) and — with
/// [showMoveInput] off — as the idle board that keeps the browse screens
/// looking like the rest of the app instead of a bare list.
class TrainingBoardPane extends StatelessWidget {
  final RepertoireBoardController session;
  final bool boardFlipped;
  final bool waitingForUser;
  final void Function(CompletedMove move)? onMove;
  final GlobalKey<MoveInputWidgetState>? moveInputKey;

  /// False while nothing is being trained: a field that can only reject what
  /// you type is worse than no field at all.
  final bool showMoveInput;

  const TrainingBoardPane({
    super.key,
    required this.session,
    required this.boardFlipped,
    required this.waitingForUser,
    this.onMove,
    this.moveInputKey,
    this.showMoveInput = true,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: 1,
                child: ChessBoardWidget(
                  key: ValueKey(session.fen),
                  position: session.position,
                  flipped: boardFlipped,
                  enableUserMoves: waitingForUser,
                  // Two half-moves while training (your move plus the reply);
                  // the idle browse board gets plain single-move highlighting
                  // like the rest of the app.
                  recentMoveSquares: session.recentMoveTrail(
                    lastN: showMoveInput ? 2 : 1,
                  ),
                  onMove: onMove,
                ),
              ),
            ),
          ),
          if (showMoveInput) ...[
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: MoveInputWidget(
                key: moveInputKey,
                position: session.position,
                enabled: waitingForUser,
                onMove: onMove ?? (_) {},
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Phase-specific training content shown beside the board (not finished/rating).
class TrainingPhasePanel extends StatelessWidget {
  final TrainingPhase phase;
  final String? feedback;
  final String? currentAnnotation;
  final bool learnQuizzing;
  final bool learnWaitingForAck;
  final bool opponentWaitingForAck;
  final MoveDisplayInfo? currentPairOpponent;
  final MoveDisplayInfo? currentPairUser;
  final int replayIndex;
  final int wrongMoveCount;
  final RepertoireLine? currentLine;
  final int currentMoveIndex;
  final bool waitingForUser;
  final bool isWhiteLine;
  final bool playingIntro;
  final double Function(RepertoireLine line, int moveIndex) moveDifficulty;
  final VoidCallback onLearnAcknowledged;
  final VoidCallback onOpponentAcknowledged;

  const TrainingPhasePanel({
    super.key,
    required this.phase,
    this.feedback,
    this.currentAnnotation,
    required this.learnQuizzing,
    required this.learnWaitingForAck,
    required this.opponentWaitingForAck,
    this.currentPairOpponent,
    this.currentPairUser,
    required this.replayIndex,
    required this.wrongMoveCount,
    this.currentLine,
    required this.currentMoveIndex,
    required this.waitingForUser,
    required this.isWhiteLine,
    this.playingIntro = false,
    required this.moveDifficulty,
    required this.onLearnAcknowledged,
    required this.onOpponentAcknowledged,
  });

  @override
  Widget build(BuildContext context) {
    final learning = phase == TrainingPhase.learning;
    final correction = feedback?.startsWith('Play ') ?? false;
    final onNext = learnWaitingForAck
        ? onLearnAcknowledged
        : opponentWaitingForAck
        ? onOpponentAcknowledged
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 32,
          child: Text(
            playingIntro
                ? 'Opening moves'
                : correction
                ? feedback!
                : phase == TrainingPhase.replaying
                ? 'Practice this line · ${replayIndex + 1} of $wrongMoveCount'
                : waitingForUser
                ? 'Your move'
                : '',
            style: AppTextStyles.body.copyWith(
              color: correction ? AppColors.warning : AppColors.onSurfaceMuted,
              fontWeight: correction ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
        Expanded(
          child: learning && currentLine != null
              ? _LessonMovetext(
                  line: currentLine!,
                  revealed:
                      (currentMoveIndex +
                              (learnQuizzing && !correction || playingIntro
                                  ? 0
                                  : 1))
                          .clamp(0, currentLine!.moves.length),
                  showComments: !learnQuizzing || correction,
                )
              : correction && currentAnnotation != null
              ? SingleChildScrollView(
                  child: Text(
                    filterDisplayComment(currentAnnotation!),
                    style: PgnTextStyles.comment(context),
                  ),
                )
              : const SizedBox.shrink(),
        ),
        SizedBox(
          height: 40,
          child: onNext == null
              ? null
              : ShortcutTooltip(
                  description: 'Next',
                  shortcut: AppShortcut.toggleSolution,
                  child: FilledButton.tonalIcon(
                    onPressed: onNext,
                    autofocus: true,
                    icon: const Icon(Icons.arrow_forward, size: 16),
                    label: const Text('Next'),
                  ),
                ),
        ),
      ],
    );
  }
}

/// The same annotated notation renderer as the PGN viewer, with only moves
/// already shown on the board supplied to it. Future moves and sidelines
/// never enter the widget, so the lesson cannot accidentally reveal answers.
class _LessonMovetext extends StatefulWidget {
  const _LessonMovetext({
    required this.line,
    required this.revealed,
    required this.showComments,
  });
  final RepertoireLine line;
  final int revealed;
  final bool showComments;
  @override
  State<_LessonMovetext> createState() => _LessonMovetextState();
}

class _LessonMovetextState extends State<_LessonMovetext> {
  PgnGameMetadata? _game;
  List<PgnMoveSnapshot> _moves = const [];
  void _readIntroduction() {
    _game = widget.line.fullPgn.isEmpty
        ? null
        : PgnGameMetadata.capture(parsePgnGame(widget.line.fullPgn));
  }

  @override
  void initState() {
    super.initState();
    _readIntroduction();
    _captureMoves();
  }

  void _captureMoves() => _moves = [
    for (int i = 0; i < widget.revealed; i++)
      PgnMoveSnapshot.capture(
        PgnNodeData(
          san: widget.line.moves[i],
          comments:
              widget.showComments && widget.line.comments[i.toString()] != null
              ? [widget.line.comments[i.toString()]!]
              : [],
        ),
        identity: i < _moves.length ? _moves[i].identity : null,
      ),
  ];
  @override
  void didUpdateWidget(_LessonMovetext oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.line != widget.line) {
      _readIntroduction();
      _moves = const [];
    }
    if (oldWidget.line != widget.line ||
        oldWidget.revealed != widget.revealed ||
        oldWidget.showComments != widget.showComments) {
      _captureMoves();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PgnMovetextView(
      game: widget.showComments && widget.revealed > 0 ? _game : null,
      moveHistory: _moves,
      variationsByPly: const {},
      mainLineIndex: widget.revealed,
      analysisPath: const [],
      editingCommentIndex: null,
      canEditComments: false,
      bookFormatting: true,
      startingMoveNumber: widget.line.startPosition.fullmoves,
      startingWhiteTurn: widget.line.startPosition.turn == Side.white,
      startPosition: widget.line.startPosition,
      onMainLineMoveClicked: (_) {},
      onShowMoveContextMenu: (_, _) {},
      onSaveComment: (_, _) {},
      onCancelEditingComment: () {},
      onGoToAnalysisNode: (_, _) {},
    );
  }
}

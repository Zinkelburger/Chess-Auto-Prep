/// Side-panel surface for an active Build-by-Playing session.
///
/// Takes over the Lines/Draft tab (same pattern as [DraftReviewPane]):
/// a subtle progress header, then a phase-dependent body — candidate list
/// with commit/skip/undo controls at a decision point, a thin progress
/// skeleton while the opponent moves, resume UI when paused, and a summary
/// when the session completes.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import '../../core/board_preview_controller.dart';
import '../../features/browse/services/candidate_service.dart';
import '../../features/browse/widgets/candidate_row.dart';
import '../../services/build_by_playing/build_by_playing_controller.dart';
import '../../theme/app_colors.dart';

class BuildSessionPane extends StatefulWidget {
  const BuildSessionPane({
    super.key,
    required this.session,
    required this.boardPreview,
    this.onOpenSettings,
  });

  final BuildByPlayingController session;
  final BoardPreviewController boardPreview;
  final VoidCallback? onOpenSettings;

  @override
  State<BuildSessionPane> createState() => _BuildSessionPaneState();
}

class _BuildSessionPaneState extends State<BuildSessionPane> {
  String? _hoveredSan;

  BuildByPlayingController get _session => widget.session;

  @override
  void initState() {
    super.initState();
    _session.addListener(_onSessionChanged);
  }

  @override
  void didUpdateWidget(covariant BuildSessionPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      oldWidget.session.removeListener(_onSessionChanged);
      widget.session.addListener(_onSessionChanged);
    }
  }

  @override
  void dispose() {
    _session.removeListener(_onSessionChanged);
    super.dispose();
  }

  void _onSessionChanged() {
    if (mounted) setState(() {});
  }

  String? _fenAfterCandidate(CandidateMove candidate) {
    final decisionFen = _session.decisionFen;
    if (decisionFen == null) return null;
    try {
      final pos = Chess.fromSetup(Setup.parseFen(decisionFen));
      final move = pos.parseSan(candidate.san);
      if (move == null) return null;
      return pos.play(move).fen;
    } catch (_) {
      return null;
    }
  }

  void _hoverCandidate(CandidateMove candidate) {
    final fen = _fenAfterCandidate(candidate);
    if (fen == null) return;
    setState(() => _hoveredSan = candidate.san);
    widget.boardPreview.setPreview(fen, lastMoveUci: candidate.uci);
  }

  void _endHover() {
    if (_hoveredSan != null) setState(() => _hoveredSan = null);
    widget.boardPreview.clearPreview();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(context),
        const Divider(height: 1),
        Expanded(child: _buildBody(context)),
      ],
    );
  }

  Widget _buildHeader(BuildContext context) {
    final theme = Theme.of(context);
    final busy =
        _session.phase == BuildByPlayingPhase.advancing ||
        _session.phase == BuildByPlayingPhase.opponentThinking ||
        _session.phase == BuildByPlayingPhase.committing;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.sports_esports,
                size: 16,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Build by playing — ${_session.progressText}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (widget.onOpenSettings != null)
                IconButton(
                  icon: const Icon(Icons.settings, size: 16),
                  tooltip: 'Session settings',
                  onPressed: widget.onOpenSettings,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 28,
                    minHeight: 28,
                  ),
                ),
              IconButton(
                icon: const Icon(Icons.close, size: 16),
                tooltip: 'End session (progress is saved as you commit)',
                onPressed: _session.endSession,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              ),
            ],
          ),
          // Fixed-height slot so the header never shifts when work starts.
          SizedBox(
            height: 3,
            child: busy
                ? const LinearProgressIndicator(minHeight: 2)
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    switch (_session.phase) {
      case BuildByPlayingPhase.idle:
        return const SizedBox.shrink();
      case BuildByPlayingPhase.paused:
        return _buildPaused(context);
      case BuildByPlayingPhase.sessionComplete:
        return _buildComplete(context);
      case BuildByPlayingPhase.advancing:
      case BuildByPlayingPhase.opponentThinking:
      case BuildByPlayingPhase.committing:
      case BuildByPlayingPhase.awaitingUserMove:
      case BuildByPlayingPhase.exploring:
        return _buildDecisionSurface(context);
    }
  }

  /// The main surface: status line, candidate list, commit/skip/undo footer.
  /// Also shown (with the list dimmed) while the opponent thinks, so the
  /// layout stays static between decision points.
  Widget _buildDecisionSurface(BuildContext context) {
    final theme = Theme.of(context);
    final atDecision =
        _session.phase == BuildByPlayingPhase.awaitingUserMove ||
        _session.phase == BuildByPlayingPhase.exploring;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Text(
            _session.statusText ?? '',
            style: theme.textTheme.bodySmall,
          ),
        ),
        Expanded(
          child: Opacity(
            opacity: atDecision ? 1.0 : 0.45,
            child: _buildCandidateList(context, enabled: atDecision),
          ),
        ),
        const Divider(height: 1),
        _buildFooter(context, enabled: atDecision),
      ],
    );
  }

  Widget _buildCandidateList(BuildContext context, {required bool enabled}) {
    if (_session.candidatesLoading) {
      return const Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    final candidates = _session.candidates;
    if (candidates.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            enabled
                ? 'No database statistics for this position — play your '
                      'move on the board and commit it.'
                : '',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: candidates.length,
      itemBuilder: (context, index) {
        final candidate = candidates[index];
        return CandidateRow(
          candidate: candidate,
          isHovered: _hoveredSan == candidate.san,
          onTap: enabled
              ? () {
                  _endHover();
                  _session.commitMove(candidate.san);
                }
              : () {},
          onHover: enabled ? () => _hoverCandidate(candidate) : () {},
          onHoverEnd: _endHover,
        );
      },
    );
  }

  Widget _buildFooter(BuildContext context, {required bool enabled}) {
    final scratchMove = _session.scratchFirstMove;
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Tooltip(
            message: scratchMove == null
                ? 'Play a move on the board or pick a candidate above'
                : 'Save $scratchMove as your repertoire move here',
            child: FilledButton.icon(
              onPressed: enabled && scratchMove != null
                  ? _session.commitScratchFirstMove
                  : null,
              icon: const Icon(Icons.check, size: 18),
              label: Text(
                scratchMove == null ? 'Commit move' : 'Commit $scratchMove',
              ),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: enabled ? _session.skipDecision : null,
                  child: const Text(
                    'Skip this position',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: OutlinedButton(
                  onPressed: _session.canUndoCommit
                      ? _session.undoLastCommit
                      : null,
                  child: const Text(
                    'Undo last commit',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPaused(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.pause_circle_outline,
              size: 32,
              color: AppColors.warning,
            ),
            const SizedBox(height: 12),
            Text(
              _session.statusText ?? 'Paused',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _session.resume,
              icon: const Icon(Icons.play_arrow, size: 18),
              label: const Text('Resume'),
            ),
            const SizedBox(height: 6),
            TextButton(
              onPressed: _session.endSession,
              child: const Text('End session'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildComplete(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.check_circle_outline,
              size: 32,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 12),
            Text(
              'Every line reached its cutoff.\n'
              '${_session.commitCount} '
              '${_session.commitCount == 1 ? 'move' : 'moves'} added to the '
              'repertoire.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _session.endSession,
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }
}

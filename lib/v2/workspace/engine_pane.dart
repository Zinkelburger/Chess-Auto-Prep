import 'dart:async';

import 'package:flutter/material.dart';

import '../chess/fen.dart';
import '../chess/pv_text.dart';
import '../ui/app_action.dart';
import '../ui/listening_state.dart';
import '../ui/theme.dart';
import 'document_session.dart';
import 'engine_analysis.dart';
import 'line_preview.dart';

/// The engine's lines for the position on the board, laid out as the old
/// app's engine bar: a compact power control and the engine's status,
/// then one fixed-height row per MultiPV line, each a score gutter and the
/// line's moves. The score is read in the gutter and nowhere larger.
///
/// A row keeps its height while it has no line yet, so the moves below never
/// jump as lines arrive; switched off, the pane takes no room.
/// Resting the pointer on a move floats the position
/// after it on a small board; clicking a move plays the line up to it.
/// A chevron opens a long line out to several rows.
class EnginePane extends StatefulWidget {
  const EnginePane({
    super.key,
    required this.session,
    required this.analysis,
    this.onMove,
  });

  final DocumentSession session;
  final EngineAnalysis analysis;

  /// Where a clicked line's moves go; null plays them into the document.
  final ValueChanged<String>? onMove;

  @override
  State<EnginePane> createState() => _EnginePaneState();
}

class _EnginePaneState extends State<EnginePane>
    with ListeningState<EnginePane> {
  final _preview = ValueNotifier<LinePreview?>(null);
  Timer? _settle;

  /// The position the rows' lines are for; null while there are none.
  Fen? _linesFor;

  @override
  void initState() {
    super.initState();
    _linesFor = widget.analysis.snapshot?.fen;
  }

  @override
  Listenable listenableOf(EnginePane widget) => widget.analysis;

  /// A row that goes takes the pointer's exit with it, so the floated board
  /// goes with the rows: when they are for another position, or gone. A
  /// deeper line for the same position keeps it.
  @override
  void changed() {
    final linesFor = widget.analysis.snapshot?.fen;
    if (linesFor == _linesFor) return;
    _linesFor = linesFor;
    _leave();
  }

  @override
  void dispose() {
    _settle?.cancel();
    _preview.dispose();
    super.dispose();
  }

  /// The board appears once the pointer has rested on a move.
  void _hover(PvMove move, Offset anchor) {
    _settle?.cancel();
    _settle = Timer(previewDelay, () {
      if (!mounted) return;
      _preview.value = LinePreview(
        fen: move.after,
        lastMove: move.uci,
        anchor: anchor,
      );
    });
  }

  void _leave() {
    _settle?.cancel();
    _preview.value = null;
  }

  /// Plays the line up to and including [index]. A move that does not
  /// land, because the document refused it, ends the walk there.
  void _play(List<PvMove> moves, int index) {
    _leave();
    final play = widget.onMove ?? widget.session.playMove;
    for (final move in moves.take(index + 1)) {
      play(move.uci);
      if (widget.analysis.position != move.after) return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.analysis, widget.session]),
      builder: (context, _) => widget.analysis.state is EngineOff
          ? const SizedBox.shrink()
          : LinePreviewOverlay(
              preview: _preview,
              orientation: widget.session.orientation,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Header(analysis: widget.analysis),
                  // Paused, only the status row remains.
                  if (widget.analysis.enabled && !widget.analysis.paused)
                    for (
                      var multiPv = 1;
                      multiPv <= widget.analysis.multiPv;
                      multiPv++
                    )
                      _row(multiPv),
                ],
              ),
            ),
    );
  }

  Widget _row(int multiPv) {
    final snapshot = widget.analysis.snapshot;
    final line = snapshot?.line(multiPv);
    if (snapshot == null || line == null) {
      return const SizedBox(height: engineRowHeight);
    }
    final moves = pvMoves(snapshot.fen, line.pv);
    return _LineRow(
      key: ValueKey('${snapshot.fen.value}:$multiPv'),
      score: line.score.text,
      moves: moves,
      onHover: _hover,
      onLeave: _leave,
      onTap: (index) => _play(moves, index),
    );
  }
}

/// The height reserved only while the engine has something to show.
double enginePaneHeight(EngineAnalysis analysis) => analysis.state is EngineOff
    ? 0
    : engineBarHeight +
          (analysis.enabled && !analysis.paused
              ? analysis.multiPv * engineRowHeight
              : 0);

/// A compact power control beside the engine's status.
class _Header extends StatelessWidget {
  const _Header({required this.analysis});

  final EngineAnalysis analysis;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final best = analysis.snapshot?.best;
    final (String status, Color? colour) = switch (analysis.state) {
      EngineOff() => ('Engine', null),
      EngineStarting() => ('Starting…', null),
      EngineFailed(:final reason) => (reason, scheme.error),
      EnginePaused(:final reason) => (reason, scheme.onSurfaceVariant),
      EngineRunning(:final name) => (
        best == null ? name : 'Depth ${best.depth} · $name',
        null,
      ),
    };
    return SizedBox(
      height: engineBarHeight,
      child: Row(
        children: [
          IconButton(
            icon: Icon(
              analysis.enabled ? Icons.power_settings_new : Icons.refresh,
              size: IconSize.menu,
            ),
            tooltip: withKey(
              analysis.enabled ? 'Turn engine off' : 'Retry engine',
              'E',
            ),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(
              width: engineBarHeight,
              height: engineBarHeight,
            ),
            onPressed: () => unawaited(
              analysis.enabled ? analysis.disable() : analysis.enable(),
            ),
          ),
          const SizedBox(width: Space.xs),
          Expanded(
            child: Tooltip(
              message: status,
              child: Text(
                status,
                style: text.labelSmall?.copyWith(color: colour),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One line: the score in its gutter, the moves clipped to a row, and a
/// chevron that opens the row out when the line is longer than a move.
class _LineRow extends StatefulWidget {
  const _LineRow({
    super.key,
    required this.score,
    required this.moves,
    required this.onHover,
    required this.onLeave,
    required this.onTap,
  });

  final String score;
  final List<PvMove> moves;
  final void Function(PvMove move, Offset anchor) onHover;
  final VoidCallback onLeave;
  final ValueChanged<int> onTap;

  @override
  State<_LineRow> createState() => _LineRowState();
}

class _LineRowState extends State<_LineRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final moves = Wrap(
      children: [
        for (final (index, move) in widget.moves.indexed)
          _MoveToken(
            move: move,
            onHover: (anchor) => widget.onHover(move, anchor),
            onLeave: widget.onLeave,
            onTap: () => widget.onTap(index),
          ),
      ],
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: scheme.outlineVariant, width: 0.5),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: engineScoreWidth,
            height: engineRowHeight,
            child: Center(
              child: Text(
                widget.score,
                style: monoText.copyWith(color: scheme.onSurface),
                maxLines: 1,
              ),
            ),
          ),
          Expanded(
            child: SizedBox(
              height: engineRowHeight * (_expanded ? engineExpandedRows : 1),
              child: _expanded
                  ? SingleChildScrollView(child: moves)
                  : ClipRect(child: moves),
            ),
          ),
          _chevron(),
        ],
      ),
    );
  }

  /// Held even when the line is a single move, so the moves column is the
  /// same width in every row.
  Widget _chevron() {
    final long = _expanded || widget.moves.length > 1;
    return SizedBox(
      width: engineRowHeight,
      height: engineRowHeight,
      child: long
          ? IconButton(
              tooltip: _expanded ? 'Collapse line' : 'Show full line',
              icon: Icon(
                _expanded ? Icons.expand_less : Icons.expand_more,
                size: IconSize.menu,
              ),
              padding: EdgeInsets.zero,
              onPressed: () {
                if (!mounted) return;
                widget.onLeave();
                setState(() => _expanded = !_expanded);
              },
            )
          : null,
    );
  }
}

/// One move in a line: its number muted, the move itself in the text
/// colour, a tint under the pointer.
class _MoveToken extends StatelessWidget {
  const _MoveToken({
    required this.move,
    required this.onHover,
    required this.onLeave,
    required this.onTap,
  });

  final PvMove move;
  final ValueChanged<Offset> onHover;
  final VoidCallback onLeave;
  final VoidCallback onTap;

  /// The bottom centre of this token on the screen, where its board hangs.
  Offset _anchor(BuildContext context) {
    final box = context.findRenderObject() as RenderBox;
    return box.localToGlobal(Offset(box.size.width / 2, box.size.height));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: engineRowHeight,
      child: MouseRegion(
        onEnter: (_) => onHover(_anchor(context)),
        onExit: (_) => onLeave(),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(3),
          hoverColor: scheme.primary.withValues(alpha: 0.1),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            // As wide as its text, or the row's loose width would be taken.
            child: Center(
              widthFactor: 1,
              child: Text.rich(
                TextSpan(
                  children: [
                    if (move.label.isNotEmpty)
                      TextSpan(
                        text: '${move.label} ',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    TextSpan(text: move.san),
                  ],
                ),
                style: monoText.copyWith(color: scheme.onSurface),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../chess/fen.dart';
import '../chess/pv_text.dart';
import '../storage/settings_store.dart';
import '../ui/engine_switch.dart';
import '../ui/listening_state.dart';
import '../ui/theme.dart';
import 'document_session.dart';
import 'engine_analysis.dart';
import 'engine_settings.dart';
import 'engine_status.dart';
import 'line_preview.dart';
import 'preview_target.dart';
import '../ui/app_keys.dart';

/// The engine's lines for the position on the board, laid out as the old
/// app's engine bar: a labelled sliding switch and the engine's status —
/// depth, speed, nodes and name — then one fixed-height row per MultiPV
/// line, each a score gutter and the line's moves. The score is read in the
/// gutter and nowhere larger.
///
/// A row keeps its height while it has no line yet, so the moves below never
/// jump as lines arrive; switched off, only the switch and status remain.
/// Resting the pointer on a move floats the position
/// after it on a small board; clicking a move plays the line up to it.
/// A chevron opens a long line out to several rows. The crosshair at the
/// status row's end shows what the side not to move threatens, as a red
/// arrow on the board; the choice is the user's setting. The gear beside it
/// turns the rows into the engine's settings and back, as Lichess's does.
class EnginePane extends StatefulWidget {
  const EnginePane({
    super.key,
    required this.session,
    required this.analysis,
    required this.settings,
    required this.settingsOpen,
    required this.coresAvailable,
    this.onMove,
  });

  final DocumentSession session;
  final EngineAnalysis analysis;

  /// Where the threat's crosshair and the gear's sliders keep their
  /// choices; the analysis follows the settings.
  final SettingsStore settings;

  /// Whether the engine's settings show in place of its lines. Held by
  /// whoever sizes the pane, since the settings may need more room.
  final ValueNotifier<bool> settingsOpen;

  /// The cores this computer has, the most the cores slider offers.
  final int coresAvailable;

  /// Where a clicked line's moves go; null plays them into the document.
  final ValueChanged<String>? onMove;

  @override
  State<EnginePane> createState() => _EnginePaneState();
}

class _EnginePaneState extends State<EnginePane>
    with ListeningState<EnginePane> {
  final _preview = HoverPreview<LinePreview>();

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
    _preview.dispose();
    super.dispose();
  }

  /// The board appears once the pointer has rested on a move.
  void _hover(PvMove move, Offset anchor) {
    _preview.rest(
      () => LinePreview(fen: move.after, lastMove: move.uci, anchor: anchor),
    );
  }

  void _leave() {
    _preview.leave();
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
      listenable: Listenable.merge([
        widget.analysis,
        widget.session,
        widget.settingsOpen,
      ]),
      builder: (context, _) => LinePreviewOverlay(
        preview: _preview,
        orientation: widget.session.orientation,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(
              analysis: widget.analysis,
              settings: widget.settings,
              settingsOpen: widget.settingsOpen,
            ),
            if (widget.settingsOpen.value)
              EngineSettingsView(
                settings: widget.settings,
                coresAvailable: widget.coresAvailable,
              )
            // Paused, only the status row remains.
            else if (widget.analysis.enabled && !widget.analysis.paused)
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

/// The height the engine keeps whether it is on, off, paused or showing
/// its settings: the switch's row and a row for each line, or for each
/// setting when those are more. Switching the engine or opening its gear
/// never changes the size of the board above it; rows with nothing in them
/// are blank.
double enginePaneHeight(EngineAnalysis analysis) =>
    engineBarHeight +
    max(analysis.multiPv, engineSettingRows) * engineRowHeight;

/// A sliding switch beside the engine's status, visible when off too, the
/// threat's crosshair and the settings' gear.
class _Header extends StatelessWidget {
  const _Header({
    required this.analysis,
    required this.settings,
    required this.settingsOpen,
  });

  final EngineAnalysis analysis;
  final SettingsStore settings;
  final ValueNotifier<bool> settingsOpen;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final best = analysis.snapshot?.best;
    final (List<String> status, Color? colour) = switch (analysis.state) {
      EngineOff() => (const ['Off'], null),
      EngineStarting() => (const ['Starting…'], null),
      EngineFailed(:final reason) => ([reason], scheme.error),
      EnginePaused(:final reason) => ([reason], scheme.onSurfaceVariant),
      EngineRunning(:final name, :final notice) => (
        engineStatusChoices(name, best, notice: notice),
        null,
      ),
    };
    return SizedBox(
      height: engineBarHeight,
      child: Row(
        children: [
          Tooltip(
            message: AppKey.engine.tip(
              analysis.enabled ? 'Turn engine off' : 'Turn engine on',
            ),
            child: Semantics(
              label: 'Engine',
              child: EngineSwitch(
                value: analysis.enabled,
                onChanged: (enabled) =>
                    unawaited(enabled ? analysis.enable() : analysis.disable()),
              ),
            ),
          ),
          const SizedBox(width: Space.xs),
          Text('Engine', style: text.labelSmall),
          const SizedBox(width: Space.s),
          const SizedBox(width: Space.xs),
          Expanded(
            child: Tooltip(
              message: status.first,
              child: _Status(
                choices: status,
                // Figures of one width, so the numbers ticking over do not
                // shuffle the words after them.
                style: text.labelSmall?.copyWith(
                  color: colour,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
          _HeaderToggle(
            icon: Icons.gps_fixed,
            tooltip: analysis.threatShown ? 'Hide threat' : 'Show threat',
            selected: analysis.threatShown,
            onPressed: analysis.enabled
                ? () => unawaited(
                    settings.update(
                      settings.value.copyWith(
                        engineThreat: !analysis.threatShown,
                      ),
                    ),
                  )
                : null,
          ),
          _HeaderToggle(
            icon: Icons.settings,
            tooltip: settingsOpen.value ? 'Show lines' : 'Engine settings',
            selected: settingsOpen.value,
            onPressed: () => settingsOpen.value = !settingsOpen.value,
          ),
        ],
      ),
    );
  }
}

/// The longest of [choices] that fits the room, the last one cut short
/// when none does: a narrow board column says the depth and the speed
/// rather than half of the engine's name. The tooltip says all of it.
class _Status extends StatelessWidget {
  const _Status({required this.choices, required this.style});

  final List<String> choices;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scaler = MediaQuery.textScalerOf(context);
      final direction = Directionality.of(context);
      final shown = choices.firstWhere((choice) {
        final painter = TextPainter(
          text: TextSpan(text: choice, style: style),
          textDirection: direction,
          textScaler: scaler,
          maxLines: 1,
        )..layout();
        final fits = painter.width <= constraints.maxWidth;
        painter.dispose();
        return fits;
      }, orElse: () => choices.last);
      return Text(
        shown,
        style: style,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    },
  );
}

/// A small icon at the header's end, muted, in the accent while it is on.
class _HeaderToggle extends StatelessWidget {
  const _HeaderToggle({
    required this.icon,
    required this.tooltip,
    required this.selected,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      icon: Icon(icon, size: IconSize.menu),
      tooltip: tooltip,
      isSelected: selected,
      color: scheme.onSurfaceVariant,
      selectedIcon: Icon(icon, size: IconSize.menu, color: scheme.primary),
      visualDensity: VisualDensity.compact,
      onPressed: onPressed,
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
          LineMoveToken(
            label: move.label,
            san: move.san,
            height: engineRowHeight,
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

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../controllers/bughouse_controller.dart';
import '../models/bughouse_state.dart';

/// What the engine thinks, kept running.
///
/// Shaped like an analysis board rather than a form: the engine is already
/// thinking when you arrive, so the eval is the first thing on the panel and
/// there is nothing to press to get one. Below it are the two answers a
/// bughouse player actually wants — what our team should do, and what the
/// other team is about to do — each broken out by who has to play it.
///
/// The rules that shape a bughouse search (which seat we hold, where we stand
/// on the clock, whether we may sit) are real inputs but are not what you look
/// at while a search runs, so they stay under one disclosure at the bottom.
class BughouseAnalysisPanel extends StatefulWidget {
  const BughouseAnalysisPanel({super.key, required this.controller});

  final BughouseController controller;

  @override
  State<BughouseAnalysisPanel> createState() => _BughouseAnalysisPanelState();
}

class _BughouseAnalysisPanelState extends State<BughouseAnalysisPanel> {
  @override
  void initState() {
    super.initState();
    // Analysis belongs to the pane being on screen, not to a controller
    // existing: this is what keeps a 54 MB network off the critical path of
    // everything else that builds one.
    widget.controller.startAnalysis();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _Eval(controller: controller),

        if (controller.error != null) ...[
          const SizedBox(height: 10),
          _Banner(message: controller.error!, isError: true),
        ],
        if (controller.notice != null) ...[
          const SizedBox(height: 10),
          _Banner(message: controller.notice!, isError: false),
        ],

        const SizedBox(height: 14),
        _TeamBlock(controller: controller, analysis: controller.ours),
        const SizedBox(height: 12),
        _TeamBlock(controller: controller, analysis: controller.theirs),

        if (controller.scenarios.isNotEmpty) ...[
          const Divider(height: 20),
          _ScenarioTable(controller: controller),
        ],

        const Divider(height: 20),
        _Settings(controller: controller),
      ],
    );
  }
}

/// The score, as prominent as it is on a board being analysed.
///
/// One number and one bar, always from our team's seat, so the sign means what
/// a reader assumes it means. The engine's own number is nowhere near this
/// readable — see [BughouseInfo.evalLabel] — and stays in the tooltip for
/// anyone comparing with the MCP tools.
class _Eval extends StatelessWidget {
  const _Eval({required this.controller});

  final BughouseController controller;

  @override
  Widget build(BuildContext context) {
    final eval = controller.eval;
    final info = controller.ours.latest ?? controller.theirs.latest;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Tooltip(
              message: _tooltip(info),
              child: Text(
                eval?.label ?? '—',
                style: AppTextStyles.mono.copyWith(
                  fontSize: 28,
                  fontWeight: FontWeight.w600,
                  color: AppColors.ink,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(child: _Bar(fraction: eval?.fraction ?? 0.5)),
            _PauseButton(controller: controller),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(child: Text(_status(), style: AppTextStyles.caption)),
            if (controller.isThinking)
              const SizedBox(
                width: 10,
                height: 10,
                child: CircularProgressIndicator(strokeWidth: 1.5),
              ),
          ],
        ),
      ],
    );
  }

  /// One line, and it says what the number is worth rather than what the
  /// engine is doing: depth and time thought are the reasons to believe it.
  String _status() {
    if (controller.isStarting) return 'Loading the network…';
    if (controller.isComparing) return 'Comparing clock scenarios…';
    final info = controller.ours.latest ?? controller.theirs.latest;
    if (info == null) {
      return controller.analysisEnabled ? 'Thinking…' : 'Paused';
    }
    final borrowed = (controller.eval?.borrowed ?? false)
        ? ' · read off their search'
        : '';
    return 'depth ${info.depth} · ${info.nodes} nodes · '
        '${(info.timeMs / 1000).round()}s$borrowed';
  }

  static String _tooltip(BughouseInfo? info) {
    const scale =
        'Our team\'s advantage: 0.00 is level, + is good for us. '
        'Hivemind\'s own scale reads about -2.30 for a level position.';
    return info == null ? scale : '$scale\nEngine says ${info.scoreLabel}.';
  }
}

/// Us against them, drawn like an eval bar because that is what it is.
class _Bar extends StatelessWidget {
  const _Bar({required this.fraction});

  final double fraction;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Our team on the left, theirs on the right',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: SizedBox(
          height: 12,
          child: Stack(
            children: [
              Row(
                children: [
                  Expanded(
                    flex: (fraction * 1000).round().clamp(1, 999),
                    child: Container(color: AppColors.ink),
                  ),
                  Expanded(
                    flex: ((1 - fraction) * 1000).round().clamp(1, 999),
                    child: Container(color: AppColors.surfaceInset),
                  ),
                ],
              ),
              // Level, marked: without it the bar says which way it leans but
              // not how far from even that is.
              const Align(
                alignment: Alignment.center,
                child: SizedBox(
                  width: 1,
                  child: ColoredBox(color: AppColors.outline),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PauseButton extends StatelessWidget {
  const _PauseButton({required this.controller});

  final BughouseController controller;

  @override
  Widget build(BuildContext context) {
    final on = controller.analysisEnabled;
    return IconButton(
      visualDensity: VisualDensity.compact,
      icon: Icon(on ? Icons.pause : Icons.play_arrow, size: 18),
      tooltip: on ? 'Stop thinking' : 'Think about this position',
      onPressed: controller.isComparing
          ? null
          : () => controller.setAnalysisEnabled(!on),
    );
  }
}

/// One team's answer: every line it looked at, best first.
///
/// One row per line, with the score in the same column on all of them —
/// showing an eval beside the alternatives but not beside the move being
/// recommended reads as though the main line had not been scored.
class _TeamBlock extends StatelessWidget {
  const _TeamBlock({required this.controller, required this.analysis});

  final BughouseController controller;
  final BughouseTeamAnalysis analysis;

  bool get _isOurs => analysis.team == controller.state.team;

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    final onMove = state.hasMoveFor(analysis.team);
    final best = analysis.best;
    final alternatives = analysis.lines.length > 1
        ? analysis.lines.skip(1).toList()
        : const <BughouseInfo>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Tooltip(
              message: _isOurs
                  ? 'You and your partner: seats ${state.teamLetters(analysis.team)}'
                  : 'The two of them: seats ${state.teamLetters(analysis.team)}',
              child: Text(
                '${_isOurs ? 'We play' : (state.hasMoveFor(state.team) ? 'They answer' : 'They play')}'
                ' · ${state.teamLetters(analysis.team)}',
                style: AppTextStyles.caption,
              ),
            ),
            const Spacer(),
            if (onMove && best != null && !best.isEmpty)
              Text(
                'click a line to play it',
                style: AppTextStyles.caption.copyWith(
                  color: AppColors.onSurfaceDim,
                ),
              ),
          ],
        ),
        if (!onMove)
          Text(
            'Nothing to move — both boards are the other team\'s.',
            style: AppTextStyles.muted,
          )
        else if (best == null)
          const Text('Thinking…', style: AppTextStyles.muted)
        else ...[
          _LineRow(
            controller: controller,
            team: analysis.team,
            action: best,
            info: analysis.latest,
            primary: true,
          ),
          for (final line in alternatives)
            if (line.pv.isNotEmpty)
              _LineRow(
                controller: controller,
                team: analysis.team,
                action: line.pv.first,
                info: line,
                primary: false,
              ),
        ],
      ],
    );
  }
}

/// `+0.02   A d4 · C exd5` — one line of a search, hoverable and playable.
///
/// Hovering lights the move up on the boards themselves, which is the reply to
/// "what does that do" that a two-board position most needs: both halves of a
/// joint action land at once, on two boards, and reading them off a text row is
/// what makes bughouse notation hard.
class _LineRow extends StatefulWidget {
  const _LineRow({
    required this.controller,
    required this.team,
    required this.action,
    required this.info,
    required this.primary,
  });

  final BughouseController controller;
  final Side team;
  final BughouseJointMove action;
  final BughouseInfo? info;

  /// The line the search settled on, drawn heavier than the ones it beat.
  final bool primary;

  @override
  State<_LineRow> createState() => _LineRowState();
}

class _LineRowState extends State<_LineRow> {
  bool _hovering = false;

  void _setHover(bool hovering) {
    if (_hovering == hovering) return;
    setState(() => _hovering = hovering);
    widget.controller.hoverAction(hovering ? widget.action : null);
  }

  @override
  void dispose() {
    if (_hovering) widget.controller.hoverAction(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final ours = widget.team == controller.state.team;
    final info = widget.info;
    final label = info == null
        ? '—'
        : ours
        ? info.evalLabel
        : BughouseController.flipEval(info.evalLabel);
    final seats = controller.describeSeats(widget.action, team: widget.team);
    final ink = widget.primary ? AppColors.ink : AppColors.onSurfaceMuted;

    return MouseRegion(
      onEnter: (_) => _setHover(true),
      onExit: (_) => _setHover(false),
      child: GestureDetector(
        onTap: () => controller.playJoint(widget.action),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
          color: _hovering ? AppColors.hoverOverlay : Colors.transparent,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 56,
                child: Text(
                  label,
                  style: AppTextStyles.mono.copyWith(
                    color: ink,
                    fontWeight: widget.primary
                        ? FontWeight.w600
                        : FontWeight.w400,
                  ),
                ),
              ),
              Expanded(
                child: Wrap(
                  spacing: 12,
                  runSpacing: 2,
                  children: [
                    for (final seat in seats)
                      Tooltip(
                        message: seat.hint,
                        child: RichText(
                          text: TextSpan(
                            children: [
                              TextSpan(
                                text: '${seat.who} ',
                                style: AppTextStyles.mono.copyWith(
                                  color: AppColors.onSurfaceDim,
                                ),
                              ),
                              TextSpan(
                                text: seat.move,
                                style: AppTextStyles.mono.copyWith(
                                  color: ink,
                                  fontWeight: widget.primary
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The inputs that are rules rather than preferences, folded away.
class _Settings extends StatelessWidget {
  const _Settings({required this.controller});

  final BughouseController controller;

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    return Theme(
      // The default tile paints a divider above and below itself, which reads
      // as a second section inside a panel that already has one.
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        title: const Text('Seat, clock and rules', style: AppTextStyles.muted),
        subtitle: Text(
          '${state.team == Side.white ? 'White' : 'Black'} on 1 · '
          '${state.timeStance.shortLabel}'
          '${controller.requireMoveOn == RequireMoveOn.none ? '' : ' · ${controller.requireMoveOn.label}'}',
          style: AppTextStyles.caption,
        ),
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Our team plays', style: AppTextStyles.caption),
          const SizedBox(height: 4),
          SegmentedButton<Side>(
            segments: const [
              ButtonSegment(value: Side.white, label: Text('White on 1')),
              ButtonSegment(value: Side.black, label: Text('Black on 1')),
            ],
            selected: {state.team},
            onSelectionChanged: (s) => controller.setTeam(s.first),
          ),
          const SizedBox(height: 12),
          _TimeAdvantage(controller: controller),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            icon: const Icon(Icons.compare_arrows, size: 16),
            label: const Text('Compare clocks'),
            onPressed: controller.isComparing
                ? null
                : controller.compareScenarios,
          ),
        ],
      ),
    );
  }
}

/// The clock relationship, which in bughouse is a rule input rather than a
/// statistic: a team that is ahead may legally sit on both boards, and the
/// engine plays completely differently when told so.
///
/// Three stances are offered because that is how players think, but the engine
/// takes one bit — so "Level" and "They are ahead" run the same search. The
/// genuinely distinct third case is [RequireMoveOn], below.
class _TimeAdvantage extends StatelessWidget {
  const _TimeAdvantage({required this.controller});

  final BughouseController controller;

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    final derived = controller.deriveTimeAdvantageFromClocks;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Clock stance', style: AppTextStyles.caption),
        const SizedBox(height: 4),
        SegmentedButton<BughouseTimeStance>(
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          segments: [
            for (final stance in BughouseTimeStance.values)
              ButtonSegment(
                value: stance,
                label: Text(stance.shortLabel),
                tooltip: stance.hint,
              ),
          ],
          selected: {state.timeStance},
          onSelectionChanged: derived
              ? null
              : (s) => controller.setTimeStance(s.first),
        ),
        const SizedBox(height: 8),

        const Text('Must the team move?', style: AppTextStyles.caption),
        const SizedBox(height: 4),
        SegmentedButton<RequireMoveOn>(
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          segments: const [
            ButtonSegment(
              value: RequireMoveOn.none,
              label: Text('Either'),
              tooltip: 'The team may pass on a board',
            ),
            ButtonSegment(
              value: RequireMoveOn.boardA,
              label: Text('On 1'),
              tooltip: 'Forbid passing on board 1',
            ),
            ButtonSegment(
              value: RequireMoveOn.boardB,
              label: Text('On 2'),
              tooltip: 'Forbid passing on board 2',
            ),
          ],
          selected: {controller.requireMoveOn},
          onSelectionChanged: (s) => controller.setRequireMoveOn(s.first),
        ),
        const SizedBox(height: 8),

        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: derived,
          onChanged: (v) => controller.setDeriveTimeAdvantage(v ?? false),
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text(
            'Set the stance from the clocks',
            style: AppTextStyles.caption,
          ),
        ),
        if (derived) ...[
          const SizedBox(height: 6),
          for (final which in BughouseBoard.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 62,
                    child: Text(which.label, style: AppTextStyles.caption),
                  ),
                  for (final side in Side.values)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: _ClockField(
                          controller: controller,
                          which: which,
                          side: side,
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}

/// One clock, entered as `m:ss` or as plain seconds.
class _ClockField extends StatefulWidget {
  const _ClockField({
    required this.controller,
    required this.which,
    required this.side,
  });

  final BughouseController controller;
  final BughouseBoard which;
  final Side side;

  @override
  State<_ClockField> createState() => _ClockFieldState();
}

class _ClockFieldState extends State<_ClockField> {
  late final TextEditingController _text = TextEditingController(
    text: _format(widget.controller.state.clocks.of(widget.which, widget.side)),
  );

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  static String _format(Duration d) {
    final minutes = d.inMinutes;
    final seconds = d.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  static Duration? _parse(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    if (!text.contains(':')) {
      final seconds = int.tryParse(text);
      return seconds == null ? null : Duration(seconds: seconds);
    }
    final parts = text.split(':');
    if (parts.length != 2) return null;
    final minutes = int.tryParse(parts[0]);
    final seconds = int.tryParse(parts[1]);
    if (minutes == null || seconds == null) return null;
    return Duration(minutes: minutes, seconds: seconds);
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _text,
      style: AppTextStyles.monoDense,
      decoration: InputDecoration(
        isDense: true,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        prefixText: widget.side == Side.white ? 'w ' : 'b ',
        prefixStyle: AppTextStyles.caption,
      ),
      onChanged: (value) {
        final parsed = _parse(value);
        if (parsed != null) {
          widget.controller.setClock(widget.which, widget.side, parsed);
        }
      },
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.message, required this.isError});
  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isError ? scheme.errorContainer : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        message,
        style: AppTextStyles.caption.copyWith(
          color: isError ? scheme.onErrorContainer : scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// The same position searched under each clock scenario, side by side.
class _ScenarioTable extends StatelessWidget {
  const _ScenarioTable({required this.controller});

  final BughouseController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Clock scenarios', style: AppTextStyles.subtitle),
        const SizedBox(height: 6),
        for (final row in controller.scenarios)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 116,
                  child: Text(row.label, style: AppTextStyles.caption),
                ),
                SizedBox(
                  width: 52,
                  child: Text(
                    row.info?.evalLabel ?? '—',
                    style: AppTextStyles.monoDense,
                  ),
                ),
                Expanded(
                  child: Text(
                    row.best == null
                        ? '—'
                        : controller.describeJoint(row.best!),
                    style: AppTextStyles.monoDense,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

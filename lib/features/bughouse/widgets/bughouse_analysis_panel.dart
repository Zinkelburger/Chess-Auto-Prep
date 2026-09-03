import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../controllers/bughouse_controller.dart';
import '../models/bughouse_engine_settings.dart';
import '../models/bughouse_state.dart';

/// What the engine thinks, kept running.
///
/// Shaped like an analysis board rather than a form: the engine is already
/// thinking when you arrive, so the eval is the first thing on the panel, it
/// stays pinned while the rest scrolls, and there is nothing to press to get
/// one. Below it are the two answers a bughouse player actually wants — what
/// our team should do, and what the other team is about to do.
///
/// Each of those is a *table*, not a sentence, and that is the point. A joint
/// action is two decisions taken together, so the shortlist has two move
/// columns headed by the seats that carry them: A and C for our team, B and D
/// for theirs. Read down a column and you see your own candidate moves; read
/// across a row and you see the pair that go together. Written as running text
/// — which is what this panel used to do — neither reading is available.
///
/// The rules that shape a bughouse search (which seat we hold, where we stand
/// on the clock, whether we may sit) and the engine's own knobs are real
/// inputs but are not what you look at while a search runs, so they sit in
/// collapsed sections at the bottom.
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
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Pinned: the score is the one thing that must never scroll away, and
        // it used to, because the whole panel sat in one scroll view.
        _Eval(controller: controller),
        if (controller.error != null) ...[
          const SizedBox(height: 10),
          _Banner(message: controller.error!, isError: true),
        ],
        if (controller.notice != null) ...[
          const SizedBox(height: 10),
          _Banner(message: controller.notice!, isError: false),
        ],
        const SizedBox(height: 12),
        Expanded(
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              _TeamLines(controller: controller, analysis: controller.ours),
              const SizedBox(height: 16),
              _TeamLines(controller: controller, analysis: controller.theirs),
              if (controller.scenarios.isNotEmpty) ...[
                const SizedBox(height: 16),
                _ScenarioTable(controller: controller),
              ],
              const SizedBox(height: 16),
              _TableRules(controller: controller),
              const SizedBox(height: 8),
              _EngineSection(controller: controller),
              const SizedBox(height: 24),
            ],
          ),
        ),
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
///
/// Play/pause leads the row rather than trailing it: it is the control that
/// governs everything to its right, and a transport button belongs before what
/// it transports.
class _Eval extends StatelessWidget {
  const _Eval({required this.controller});

  final BughouseController controller;

  @override
  Widget build(BuildContext context) {
    final eval = controller.eval;
    final info = controller.ours.latest ?? controller.theirs.latest;
    final on = controller.analysisEnabled;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: Icon(on ? Icons.pause : Icons.play_arrow, size: 22),
              tooltip: on ? 'Stop thinking' : 'Think about this position',
              onPressed: controller.isComparing
                  ? null
                  : () => controller.setAnalysisEnabled(!on),
            ),
            const SizedBox(width: 4),
            Tooltip(
              message: _tooltip(info),
              child: Text(
                eval?.label ?? '—',
                style: AppTextStyles.mono.copyWith(
                  fontSize: 26,
                  fontWeight: FontWeight.w600,
                  color: AppColors.ink,
                ),
              ),
            ),
            const SizedBox(width: 12),
            // The percentage rather than a bar: Hivemind's score is an MCTS
            // Q-value, so an expected score is the one reading of it that is
            // exact rather than drawn to scale.
            if (eval != null)
              Tooltip(
                message:
                    'Our team\'s expected score, from the engine\'s own '
                    'value. 50% is level.',
                child: Text(
                  '${eval.winPercent.round()}% for us',
                  style: AppTextStyles.body.copyWith(
                    color: AppColors.onSurfaceMuted,
                  ),
                ),
              ),
            const Spacer(),
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
    const scale = 'Our team\'s advantage: 0.00 is level, + is good for us.';
    if (info == null) return scale;
    // Which baseline applies depends on the clock stance the search ran under,
    // so name the one that produced this number rather than a fixed figure.
    return '$scale\nEngine says ${info.scoreLabel}; its own scale reads '
        '${info.levelBaseline.toStringAsFixed(2)} for a level position '
        '${info.hadTimeAdvantage ? 'when the team may sit' : 'when it may not'}.';
  }
}

/// One team's shortlist, laid out as a table of the two seats that play it.
class _TeamLines extends StatelessWidget {
  const _TeamLines({required this.controller, required this.analysis});

  final BughouseController controller;
  final BughouseTeamAnalysis analysis;

  bool get _isOurs => analysis.team == controller.state.team;

  /// Width of the score column. Wide enough for `-12.34` and `#-3`, and fixed
  /// so every score in both tables sits on the same axis.
  static const double evalWidth = 54;

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    final onMove = state.hasMoveFor(analysis.team);
    final best = analysis.best;
    // Every row in this block comes from the same finished search. The primary
    // used to show `latest`, which advances live during the pass in progress
    // while the alternatives still hold the previous pass's block — and since
    // passes double up to the think-time cap, the numbers being compared side
    // by side came from budgets a factor of two apart. `latest` still drives
    // the headline eval and the depth caption, where a live figure is what a
    // reader wants.
    final ranked = analysis.lines;
    final primary = ranked.isNotEmpty ? ranked.first : analysis.latest;
    final alternatives = ranked.length > 1
        ? ranked.skip(1).toList()
        : const <BughouseInfo>[];

    // Our seats are A (board 1) and C (board 2); theirs are B and D. Naming
    // the columns is what turns a row of moves into "who plays what".
    final seats = [
      for (final which in BughouseBoard.values)
        state.seatLetter(
          which,
          which == BughouseBoard.a ? analysis.team : analysis.team.opposite,
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              _isOurs ? 'WE PLAY' : 'THEY PLAY',
              style: AppTextStyles.eyebrow,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Tooltip(
                message: _isOurs ? 'You and your partner' : 'The two of them',
                child: Text(
                  state.teamLetters(analysis.team),
                  style: AppTextStyles.caption,
                ),
              ),
            ),
            if (onMove && best != null && !best.isEmpty)
              Text(
                'click to play',
                style: AppTextStyles.caption.copyWith(
                  color: AppColors.onSurfaceMuted,
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        if (!onMove)
          Text(
            'Nothing to move — both boards are the other team\'s.',
            style: AppTextStyles.muted,
          )
        else if (best == null)
          const Text('Thinking…', style: AppTextStyles.muted)
        else ...[
          _ColumnHeader(seats: seats),
          _LineRow(
            controller: controller,
            team: analysis.team,
            action: best,
            info: primary,
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

/// `      A        C` — the seats the two move columns belong to.
class _ColumnHeader extends StatelessWidget {
  const _ColumnHeader({required this.seats});

  final List<String> seats;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 2),
      child: Row(
        children: [
          const SizedBox(width: _TeamLines.evalWidth),
          for (final seat in seats)
            Expanded(
              child: Text(
                seat,
                style: AppTextStyles.mono.copyWith(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.onSurfaceMuted,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// `+0.02   Nc3   exd5` — one line of a search, hoverable and playable.
///
/// Hovering lights the move up on the boards themselves *and* draws it as an
/// arrow, which is the reply to "what does that do" that a two-board position
/// most needs: both halves of a joint action land at once, on two boards, and
/// reading them off a text row is what makes bughouse notation hard. Hovering
/// also opens the line's continuation underneath, in SAN and in the same two
/// columns — the engine's `pv` is a list of joint actions in board-prefixed
/// UCI, which is unreadable as printed and is why it was never shown at all.
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
    // Only if this row still owns the highlight — another row may have taken
    // it already — and never with a notification, because `dispose` runs with
    // the tree locked.
    if (_hovering) {
      widget.controller.clearHoverIfOwned(widget.action, silently: true);
    }
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
    final weight = widget.primary ? FontWeight.w600 : FontWeight.w400;

    // Keyed by board so the two columns line up down the table even when one
    // seat has nothing to play on a given line.
    final byBoard = {for (final seat in seats) seat.board: seat};

    return MouseRegion(
      onEnter: (_) => _setHover(true),
      onExit: (_) => _setHover(false),
      child: GestureDetector(
        onTap: () => controller.playJoint(widget.action),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
          color: _hovering ? AppColors.hoverOverlay : Colors.transparent,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  SizedBox(
                    width: _TeamLines.evalWidth,
                    child: Text(
                      label,
                      style: AppTextStyles.mono.copyWith(
                        color: ink,
                        fontWeight: weight,
                      ),
                    ),
                  ),
                  for (final which in BughouseBoard.values)
                    Expanded(
                      child: Tooltip(
                        message: byBoard[which]?.hint ?? '',
                        child: Text(
                          byBoard[which]?.move ?? '',
                          style: AppTextStyles.mono.copyWith(
                            color: ink,
                            fontWeight: weight,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              if (_hovering && info != null)
                _Continuation(
                  controller: controller,
                  info: info,
                  team: widget.team,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The rest of the engine's line, in SAN, under the row it belongs to.
class _Continuation extends StatelessWidget {
  const _Continuation({
    required this.controller,
    required this.info,
    required this.team,
  });

  final BughouseController controller;
  final BughouseInfo info;
  final Side team;

  @override
  Widget build(BuildContext context) {
    // The first ply is the row above; what is worth showing is what follows.
    final steps = controller.describePv(info, team: team, maxPlies: 5);
    if (steps.length < 2) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final step in steps.skip(1))
            Row(
              children: [
                // A variation alternates teams, so the columns stop belonging
                // to the seats in the header after the first ply. Naming the
                // pair that plays each row is what keeps it readable — the
                // columns themselves stay boards throughout.
                SizedBox(
                  width: _TeamLines.evalWidth,
                  child: Text(
                    step.seats,
                    style: AppTextStyles.monoDense.copyWith(
                      color: AppColors.onSurfaceMuted,
                    ),
                  ),
                ),
                for (final which in BughouseBoard.values)
                  Expanded(
                    child: Text(
                      step.on(which) ?? '',
                      style: AppTextStyles.monoDense.copyWith(
                        color: AppColors.onSurfaceMuted,
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

/// A collapsed group of inputs, with the values it holds printed on its lid so
/// you never have to open it just to see where things stand.
class _Section extends StatefulWidget {
  const _Section({
    required this.title,
    required this.summary,
    required this.children,
  });

  final String title;
  final String summary;
  final List<Widget> children;

  @override
  State<_Section> createState() => _SectionState();
}

class _SectionState extends State<_Section> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.divider),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.title, style: AppTextStyles.eyebrow),
                        const SizedBox(height: 2),
                        Text(
                          widget.summary,
                          style: AppTextStyles.caption,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    _open ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: AppColors.onSurfaceMuted,
                  ),
                ],
              ),
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: widget.children,
              ),
            ),
        ],
      ),
    );
  }
}

/// The inputs that are rules of the table rather than preferences.
class _TableRules extends StatelessWidget {
  const _TableRules({required this.controller});

  final BughouseController controller;

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    final derived = controller.deriveTimeAdvantageFromClocks;

    return _Section(
      title: 'Table',
      summary:
          '${state.team == Side.white ? 'White' : 'Black'} on board 1 · '
          '${state.timeStance.shortLabel}'
          '${controller.requireMoveOn == RequireMoveOn.none ? '' : ' · ${controller.requireMoveOn.label}'}',
      children: [
        const _Label('Our team plays'),
        SegmentedButton<Side>(
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          segments: const [
            ButtonSegment(value: Side.white, label: Text('White on 1')),
            ButtonSegment(value: Side.black, label: Text('Black on 1')),
          ],
          selected: {state.team},
          onSelectionChanged: (s) => controller.setTeam(s.first),
        ),
        const SizedBox(height: 12),

        // The clock relationship is a rule input, not a statistic: a team that
        // is ahead on the diagonal may legally sit on both boards, and the
        // engine plays completely differently when told so. Three stances are
        // offered because that is how players think, but the engine takes one
        // bit — "Level" and "Behind" run the same search. The genuinely
        // distinct third case is the must-move constraint below.
        const _Label('Clock stance'),
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
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: derived,
          onChanged: (v) => controller.setDeriveTimeAdvantage(v ?? false),
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text(
            'Read it off the four clocks',
            style: AppTextStyles.caption,
          ),
        ),
        const SizedBox(height: 4),

        const _Label('Must the team move?'),
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
        const SizedBox(height: 10),
        OutlinedButton.icon(
          icon: const Icon(Icons.compare_arrows, size: 16),
          label: const Text('Compare clock scenarios'),
          onPressed: controller.isComparing
              ? null
              : controller.compareScenarios,
        ),
      ],
    );
  }
}

/// How hard the engine works, and what it is working with.
class _EngineSection extends StatelessWidget {
  const _EngineSection({required this.controller});

  final BughouseController controller;

  @override
  Widget build(BuildContext context) {
    final settings = controller.engineSettings;
    final detail = controller.backendDetail;

    return _Section(
      title: 'Engine',
      summary:
          '${settings.hashMb} MB · batch ${settings.batchSize} · '
          '${settings.lines} line${settings.lines == 1 ? '' : 's'} · '
          '${settings.thinkSeconds}s a pass',
      children: [
        _Knob(
          label: 'Memory',
          hint: 'The search tree\'s hash table.',
          value: settings.hashMb,
          choices: BughouseEngineSettings.hashChoices,
          format: (v) => '$v MB',
          onChanged: (v) =>
              controller.setEngineSettings(settings.copyWith(hashMb: v)),
        ),
        _Knob(
          label: 'Batch',
          hint:
              'Positions sent to the network at once. Larger keeps more of '
              'the CPU busy per evaluation and raises nodes per second; it '
              'also makes the search coarser.',
          value: settings.batchSize,
          choices: BughouseEngineSettings.batchChoices,
          format: (v) => '$v',
          onChanged: (v) =>
              controller.setEngineSettings(settings.copyWith(batchSize: v)),
        ),
        _Knob(
          label: 'Lines',
          hint: 'How many ranked moves each pass reports.',
          value: settings.lines,
          choices: BughouseEngineSettings.lineChoices,
          format: (v) => '$v',
          onChanged: (v) =>
              controller.setEngineSettings(settings.copyWith(lines: v)),
        ),
        _Knob(
          label: 'Think',
          hint:
              'The longest one pass runs for. Hivemind has no "go infinite", '
              'so thinking is built from passes that each run longer than the '
              'last; this is where that stops.',
          value: settings.thinkSeconds,
          choices: BughouseEngineSettings.thinkChoices,
          format: (v) => '${v}s',
          onChanged: (v) =>
              controller.setEngineSettings(settings.copyWith(thinkSeconds: v)),
        ),
        const SizedBox(height: 8),
        // There is no core count to set: Hivemind does not advertise a
        // `Threads` option and ignores one if it is sent, fixing its worker
        // count at build time. So this reports what it chose rather than
        // pretending to control it — the batch above is the knob that actually
        // changes how much work reaches the CPU.
        Text(
          detail.isEmpty
              ? 'The engine reports its worker and thread counts once it is '
                    'running; it has no setting for them.'
              : '${controller.backendLabel} · $detail. The worker and thread '
                    'counts are fixed by the engine build.',
          style: AppTextStyles.caption,
        ),
      ],
    );
  }
}

/// One labelled dropdown, laid out so a column of them lines up.
class _Knob extends StatelessWidget {
  const _Knob({
    required this.label,
    required this.hint,
    required this.value,
    required this.choices,
    required this.format,
    required this.onChanged,
  });

  final String label;
  final String hint;
  final int value;
  final List<int> choices;
  final String Function(int) format;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: Tooltip(
              message: hint,
              child: Text(label, style: AppTextStyles.muted),
            ),
          ),
          Expanded(
            child: DropdownButtonFormField<int>(
              initialValue: value,
              isDense: true,
              style: AppTextStyles.mono,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 8,
                ),
              ),
              items: [
                for (final choice in choices)
                  DropdownMenuItem(
                    value: choice,
                    child: Text(format(choice), style: AppTextStyles.mono),
                  ),
              ],
              onChanged: (v) => v == null ? null : onChanged(v),
            ),
          ),
        ],
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(text, style: AppTextStyles.caption),
  );
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
        const Text('CLOCK SCENARIOS', style: AppTextStyles.eyebrow),
        const SizedBox(height: 6),
        for (final row in controller.scenarios)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 110,
                  child: Text(row.label, style: AppTextStyles.caption),
                ),
                SizedBox(
                  width: _TeamLines.evalWidth,
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

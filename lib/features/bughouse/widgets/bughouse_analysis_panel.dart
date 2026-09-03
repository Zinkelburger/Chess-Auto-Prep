import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../controllers/bughouse_controller.dart';
import '../models/bughouse_engine_settings.dart';
import '../models/bughouse_eval.dart';
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
/// One number and one percentage, always from our team's seat, so the sign
/// means what a reader assumes it means. Both are read off the same
/// [BughouseEval], which is the engine's value with the offset measured for
/// *this* position taken out; the engine's own raw number is nowhere near
/// readable and stays in the tooltip for anyone comparing with the MCP tools.
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
              message: _tooltip(info, eval, controller.calibration),
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
            // exact rather than drawn to scale. Read off the same value as the
            // number beside it, so the two cannot disagree.
            if (eval != null)
              Tooltip(
                message:
                    'Our team\'s expected score, from the engine\'s own '
                    'value. 50% is level.',
                child: Text(
                  '${eval.winLabel} for us',
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

  static String _tooltip(
    BughouseInfo? info,
    BughouseEval? eval,
    BughouseCalibration calibration,
  ) {
    const scale = 'Our team\'s advantage: 0.00 is level, + is good for us.';
    if (info == null || eval == null) return scale;
    // Where the zero came from, not a fixed figure: the offset in a raw score
    // is measured from both teams' searches and is different in every
    // position.
    return '$scale\nEngine says ${info.scoreLabel}. ${calibration.note}';
  }
}

/// One team's shortlist: the ranked lines of its last finished pass, laid
/// out the way every engine pane in this app lays lines out — a score, then
/// the line in SAN with every move of it clickable.
///
/// The first ply of a line is the candidate the row is ranked by, drawn
/// heavier; what follows is the continuation the engine expects. A bughouse
/// ply is a joint action on two boards, so each move carries the letter of
/// the seat that plays it — `A d4` is ours on board 1, `D d5` is their
/// partner's on board 2 — and plies are separated by a dot. Hovering a move
/// draws it on the boards; clicking one plays the line through it, and
/// clicking the row plays its first ply. Nothing about a row changes shape
/// when the pointer crosses it: the continuation used to unfold under the
/// pointer, which moved every row below it and put a different row under the
/// pointer than the one it had entered.
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
    // Every row comes from the same finished search. Showing `latest` in the
    // top row while the others held the previous block put numbers from
    // budgets a factor of two apart side by side; `latest` still drives the
    // headline eval, where a live figure is what a reader wants.
    final rows = analysis.lines.isNotEmpty
        ? analysis.lines
        : [?analysis.latest];

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
          ],
        ),
        const SizedBox(height: 4),
        if (!onMove)
          const Text(
            'Nothing to move — both boards are the other team\'s.',
            style: AppTextStyles.muted,
          )
        else if (rows.isEmpty && analysis.best == null)
          const Text('Thinking…', style: AppTextStyles.muted)
        else ...[
          for (var i = 0; i < rows.length; i++)
            if (rows[i].pv.isNotEmpty)
              _LineRow(
                // Keyed by content, so a row whose line changes under the
                // pointer is a new row: the pointer leaves the old one and
                // enters the new, instead of the old highlight outliving it.
                key: ValueKey('${analysis.team.name}:$i:${rows[i].pv}'),
                controller: controller,
                team: analysis.team,
                steps: controller.describePv(rows[i], team: analysis.team),
                label: controller.evalOf(rows[i], team: analysis.team).label,
                primary: i == 0,
              ),
          // A `bestmove` with no line behind it — the engine's first word
          // before any `info` — is still worth a row.
          if (rows.every((r) => r.pv.isEmpty) && analysis.best != null)
            _LineRow(
              key: ValueKey('${analysis.team.name}:best:${analysis.best}'),
              controller: controller,
              team: analysis.team,
              steps: controller.describePv(
                BughouseInfo(
                  depth: 0,
                  scoreCp: 0,
                  nodes: 0,
                  nps: 0,
                  timeMs: 0,
                  pv: [analysis.best!],
                ),
                team: analysis.team,
              ),
              label: '—',
              primary: true,
            ),
        ],
      ],
    );
  }
}

/// `+0.02   A Nf3 · B e5 D d5 · A Nc3` — one line of a search.
///
/// Stateful for one bit, whether the pointer is over it, which tints the row
/// and is what the boards' highlight follows. The state object doubles as the
/// highlight's owner: a row that is unmounted while lit clears its own
/// highlight and nobody else's, after the frame, because `dispose` runs with
/// the tree locked and the boards listening to the highlight would rebuild.
class _LineRow extends StatefulWidget {
  const _LineRow({
    super.key,
    required this.controller,
    required this.team,
    required this.steps,
    required this.label,
    required this.primary,
  });

  final BughouseController controller;
  final Side team;

  /// The line, replayed from the position on screen. Empty when it no longer
  /// fits — what a line from a superseded search looks like.
  final List<BughousePvStep> steps;

  /// The score, already printed from our seat.
  final String label;

  /// The line the search settled on, drawn heavier than the ones it beat.
  final bool primary;

  @override
  State<_LineRow> createState() => _LineRowState();
}

class _LineRowState extends State<_LineRow> {
  bool _lit = false;

  BughouseController get _controller => widget.controller;

  void _enterRow() {
    setState(() => _lit = true);
    if (widget.steps.isNotEmpty) {
      _controller.hoverStep(widget.steps.first, owner: this);
    }
  }

  void _exitRow() {
    setState(() => _lit = false);
    _controller.clearHover(this);
  }

  /// Leaving a move falls back to the row's own candidate rather than to
  /// nothing: the pointer is still on the row.
  void _exitStep() {
    if (_lit && widget.steps.isNotEmpty) {
      _controller.hoverStep(widget.steps.first, owner: this);
    }
  }

  @override
  void dispose() {
    if (_lit) {
      final controller = _controller;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!controller.isDisposed) controller.clearHover(this);
      });
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final steps = widget.steps;
    final state = _controller.state;
    final ink = widget.primary ? AppColors.ink : AppColors.onSurfaceMuted;
    final weight = widget.primary ? FontWeight.w600 : FontWeight.w400;

    return MouseRegion(
      cursor: steps.isEmpty
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      onEnter: (_) => _enterRow(),
      onExit: (_) => _exitRow(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: steps.isEmpty
            ? null
            : () => _controller.playLine(steps, throughPly: 0),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
          decoration: BoxDecoration(
            color: _lit ? AppColors.hoverOverlay : Colors.transparent,
            borderRadius: BorderRadius.circular(3),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: _TeamLines.evalWidth,
                child: Padding(
                  // Sits on the first line of the moves beside it.
                  padding: const EdgeInsets.only(top: 1),
                  child: Text(
                    widget.label,
                    style: AppTextStyles.mono.copyWith(
                      color: ink,
                      fontWeight: weight,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: steps.isEmpty
                    ? Text(
                        'no longer fits this position',
                        style: AppTextStyles.monoDense.copyWith(
                          color: AppColors.onSurfaceMuted,
                        ),
                      )
                    : Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        runSpacing: 2,
                        children: [
                          for (var i = 0; i < steps.length; i++) ...[
                            if (i > 0) const _PlyDot(),
                            for (final which in BughouseBoard.values)
                              if (steps[i].on(which) case final san?)
                                _MoveToken(
                                  seat: steps[i].seatOn(which, state),
                                  san: san,
                                  ink: i == 0 ? ink : AppColors.onSurfaceMuted,
                                  weight: i == 0 ? weight : FontWeight.w400,
                                  onEnter: () => _controller.hoverStep(
                                    steps[i],
                                    owner: this,
                                  ),
                                  onExit: _exitStep,
                                  onTap: () => _controller.playLine(
                                    steps,
                                    throughPly: i,
                                  ),
                                ),
                          ],
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

/// The gap between two plies of a line. A dot rather than a move number,
/// because a line across two boards has no single number to count by: each
/// board counts its own moves, and a ply here may touch both.
class _PlyDot extends StatelessWidget {
  const _PlyDot();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 3),
    child: Text(
      '·',
      style: AppTextStyles.monoDense.copyWith(color: AppColors.onSurfaceDim),
    ),
  );
}

/// One seat's move in a line: the seat letter, muted, then the SAN — `A Nf3`,
/// `D P@e5`, `C sit`. Dotted-underlined the way the app's other engine lines
/// mark a move that can be clicked.
class _MoveToken extends StatelessWidget {
  const _MoveToken({
    required this.seat,
    required this.san,
    required this.ink,
    required this.weight,
    required this.onEnter,
    required this.onExit,
    required this.onTap,
  });

  final String seat;
  final String san;
  final Color ink;
  final FontWeight weight;
  final VoidCallback onEnter;
  final VoidCallback onExit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => onEnter(),
      onExit: (_) => onExit(),
      child: GestureDetector(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '$seat ',
                  style: AppTextStyles.monoDense.copyWith(
                    color: AppColors.onSurfaceMuted,
                  ),
                ),
                TextSpan(
                  text: san,
                  style: AppTextStyles.mono.copyWith(
                    color: ink,
                    fontWeight: weight,
                    decoration: TextDecoration.underline,
                    decorationStyle: TextDecorationStyle.dotted,
                    decorationColor: AppColors.onSurfaceDim,
                  ),
                ),
              ],
            ),
          ),
        ),
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
                    row.eval?.label ?? '—',
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

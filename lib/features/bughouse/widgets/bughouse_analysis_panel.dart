import 'dart:async';

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../theme/pgn_text_styles.dart';
import '../../../widgets/copy_button.dart';
import '../controllers/bughouse_controller.dart';
import '../models/bughouse_engine_settings.dart';
import '../models/bughouse_eval.dart';
import '../models/bughouse_state.dart';
import '../../../widgets/common/number_stepper.dart';
import '../../../widgets/shortcut_tooltip.dart';
import '../../../utils/app_shortcuts.dart';
import 'bughouse_book_panel.dart';
import '../services/bughouse_cpu_limit.dart';
import 'bughouse_panel_section.dart';

/// Analysis, rules and engine settings beside the two boards.
class BughouseAnalysisPanel extends StatefulWidget {
  const BughouseAnalysisPanel({super.key, required this.controller});

  final BughouseController controller;

  @override
  State<BughouseAnalysisPanel> createState() => _BughouseAnalysisPanelState();
}

class _BughouseAnalysisPanelState extends State<BughouseAnalysisPanel>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  bool _wasComparing = false;
  final _outputScroll = ScrollController();
  int _tab = 0;
  bool _bookWasOpen = false;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    // Analysis belongs to the pane being on screen, not to a controller
    // existing: this is what keeps a 54 MB network off the critical path of
    // everything else that builds one.
    widget.controller.startAnalysis();
  }

  @override
  void dispose() {
    _outputScroll.dispose();
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    if (controller.bookOpen && !_bookWasOpen) {
      _tab = 0;
      _tabs.index = 0;
    }
    _bookWasOpen = controller.bookOpen;
    if (controller.isComparing && !_wasComparing) {
      _tab = 0;
      _tabs.index = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        controller.hoverAction(null);
        if (_outputScroll.hasClients) _outputScroll.jumpTo(0);
      });
    }
    _wasComparing = controller.isComparing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Pinned: the score is the one thing that must never scroll away, and
        // it used to, because the whole panel sat in one scroll view.
        _Eval(controller: controller),
        if (controller.error != null) ...[
          const SizedBox(height: 10),
          _Banner(
            message: controller.error!,
            isError: true,
            details: controller.errorReport,
            helpUrl: controller.errorLink,
          ),
        ],
        if (controller.notice != null) ...[
          const SizedBox(height: 10),
          _Banner(message: controller.notice!, isError: false),
        ],
        const SizedBox(height: 8),
        TabBar(
          controller: _tabs,
          labelColor: AppColors.ink,
          unselectedLabelColor: AppColors.onSurfaceMuted,
          labelStyle: AppTextStyles.bodyStrong,
          unselectedLabelStyle: AppTextStyles.body,
          labelPadding: const EdgeInsets.symmetric(horizontal: 8),
          indicatorColor: AppColors.ink,
          indicatorSize: TabBarIndicatorSize.tab,
          dividerColor: AppColors.divider,
          tabs: const [
            Tab(text: 'Engine'),
            Tab(text: 'Board'),
            Tab(text: 'Engine settings'),
          ],
          onTap: (index) {
            if (!mounted) return;
            controller.hoverAction(null);
            setState(() => _tab = index);
          },
        ),
        const SizedBox(height: 12),
        Expanded(
          child: ListView(
            controller: _outputScroll,
            padding: EdgeInsets.zero,
            children: switch (_tab) {
              1 => [_TableRules(controller: controller)],
              2 => [_EngineSection(controller: controller)],
              _ => [
                if (controller.isComparing ||
                    controller.scenarios.isNotEmpty) ...[
                  _ScenarioTable(controller: controller),
                  const SizedBox(height: 16),
                  Text(
                    controller.isComparing
                        ? 'CURRENT CLOCK SETTINGS · PAUSED'
                        : 'CURRENT CLOCK SETTINGS',
                    style: AppTextStyles.eyebrow,
                  ),
                  const SizedBox(height: 8),
                ],
                for (final which in BughouseBoard.values) ...[
                  _BoardLines(controller: controller, which: which),
                  const SizedBox(height: 12),
                ],
                if (controller.bookOpen) ...[
                  const Divider(height: 24),
                  BughouseBookPanel(controller: controller),
                ],
              ],
            },
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
              tooltip: actionTooltip(
                on ? 'Pause analysis' : 'Resume analysis',
                shortcut: AppShortcut.autoPlay,
              ),
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
            const Expanded(
              child: Text(
                'You + Partner',
                style: AppTextStyles.muted,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              tooltip: 'Edit position',
              icon: const Icon(Icons.edit_outlined, size: 18),
              onPressed: () => controller.setMode(BughouseMode.setup),
            ),
            IconButton(
              tooltip: 'Engine tournament',
              icon: const Icon(Icons.emoji_events_outlined, size: 18),
              onPressed: () => controller.setMode(BughouseMode.tournament),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(child: Text(_status(), style: AppTextStyles.caption)),
            if (controller.isThinking || controller.isComparing)
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
    if (controller.isComparing) return 'Comparing clock scenarios…';
    if (controller.isStarting) return 'Loading the network…';
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

/// Ranked continuations for whoever is to move on one board.
/// The underlying search still considers both boards and their shared pieces.
class _BoardLines extends StatelessWidget {
  const _BoardLines({required this.controller, required this.which});

  final BughouseController controller;
  final BughouseBoard which;

  /// Width of the score column. Wide enough for `-12.34` and `#-3`, and fixed
  /// so every score in both tables sits on the same axis.
  static const double evalWidth = 54;

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    final turn = state.board(which).turn;
    final analysis = state.isOurTurn(which)
        ? controller.ours
        : controller.theirs;
    // Every row comes from the same finished search. Showing `latest` in the
    // top row while the others held the previous block put numbers from
    // budgets a factor of two apart side by side; `latest` still drives the
    // headline eval, where a live figure is what a reader wants.
    final rows = analysis.lines.isNotEmpty
        ? analysis.lines
        : [?analysis.latest];

    // What goes in the slots: the ranked lines, or the engine's first word
    // before any `info` — a `bestmove` with no line behind it is still worth
    // a row.
    final lines = <Widget>[
      for (var i = 0; i < rows.length; i++)
        if (rows[i].pv.isNotEmpty)
          _LineRow(
            // Keyed by content, so a row whose line changes under the
            // pointer is a new row: the pointer leaves the old one and
            // enters the new, instead of the old highlight outliving it.
            key: ValueKey(
              '${which.name}:${analysis.team.name}:$i:${rows[i].pv}',
            ),
            controller: controller,
            which: which,
            steps: controller.describePv(rows[i], team: analysis.team),
            label: controller.evalOf(rows[i], team: analysis.team).label,
            primary: i == 0,
          ),
      if (rows.every((r) => r.pv.isEmpty) && analysis.best != null)
        _LineRow(
          key: ValueKey(
            '${which.name}:${analysis.team.name}:best:${analysis.best}',
          ),
          controller: controller,
          which: which,
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
    ];
    final String? message = lines.isEmpty
        ? (controller.analysisEnabled ? 'Thinking…' : 'Analysis paused')
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            children: [
              Text(which.label, style: AppTextStyles.bodyStrong),
              const SizedBox(width: 8),
              Text(
                '${turn == Side.white ? 'White' : 'Black'} to move',
                style: AppTextStyles.caption,
              ),
              const Spacer(),
              const Tooltip(
                message:
                    'Best lines for the side to move on this board. '
                    'Both boards are analysed together; scores are for your team. '
                    'Hover previews both boards. Clicking plays the full joint sequence.',
                child: Icon(
                  Icons.info_outline,
                  size: 16,
                  color: AppColors.onSurfaceMuted,
                ),
              ),
            ],
          ),
        ),
        // As many slots as lines the engine is asked for, every one the same
        // height, whether or not there is a line to put in it yet.
        for (var i = 0; i < controller.shortlistSize; i++)
          SizedBox(
            key: ValueKey('bughouse-line-slot-${which.name}-$i'),
            height: _LineRow.height,
            child: i < lines.length
                ? lines[i]
                : i == 0 && message != null
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(4, 3, 4, 0),
                    child: Text(message, style: AppTextStyles.muted),
                  )
                : null,
          ),
      ],
    );
  }
}

/// One board’s part of a joint continuation, with stable row height.
class _LineRow extends StatefulWidget {
  const _LineRow({
    super.key,
    required this.controller,
    required this.which,
    required this.steps,
    required this.label,
    required this.primary,
  });

  final BughouseController controller;
  final BughouseBoard which;

  /// The line, replayed from the position on screen. Empty when it no longer
  /// fits — what a line from a superseded search looks like.
  final List<BughousePvStep> steps;

  /// The score, already printed from our seat.
  final String label;

  /// The line the search settled on, drawn heavier than the ones it beat.
  final bool primary;

  /// One horizontally scrollable move strip, empty or full.
  static const double height = 36;

  @override
  State<_LineRow> createState() => _LineRowState();
}

class _LineRowState extends State<_LineRow> {
  bool _lit = false;

  BughouseController get _controller => widget.controller;

  void _enterRow() {
    if (!mounted) return;
    setState(() => _lit = true);
    if (widget.steps.isNotEmpty) {
      _controller.hoverStep(widget.steps.first, owner: this);
    }
  }

  void _exitRow() {
    if (!mounted) return;
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

  List<Widget> _movesOn(BughouseBoard which) {
    final moves = <Widget>[];
    final steps = widget.steps;
    for (var i = 0; i < steps.length; i++) {
      final san = steps[i].on(which);
      if (san == null) continue;
      final position = steps[i].before.board(which);
      final first = moves.isEmpty;
      final number = san == 'sit'
          ? ''
          : position.turn == Side.white
          ? '${position.fullmoves}.'
          : first
          ? '${position.fullmoves}...'
          : '';
      moves.add(
        _MoveToken(
          number: number,
          san: san,
          onEnter: () => _controller.hoverStep(steps[i], owner: this),
          onExit: _exitStep,
          onTap: () => _controller.playLine(steps, throughPly: i),
        ),
      );
    }
    return moves.isEmpty
        ? [const Text('—', style: AppTextStyles.muted)]
        : moves;
  }

  @override
  Widget build(BuildContext context) {
    final steps = widget.steps;
    const ink = AppColors.ink;
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
          height: _LineRow.height,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          decoration: BoxDecoration(
            color: _lit ? AppColors.hoverOverlay : Colors.transparent,
            border: const Border(bottom: BorderSide(color: AppColors.divider)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: _BoardLines.evalWidth,
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
                    : SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(children: _movesOn(widget.which)),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A numbered move. Hover previews both boards; click plays through it.
class _MoveToken extends StatelessWidget {
  const _MoveToken({
    required this.number,
    required this.san,
    required this.onEnter,
    required this.onExit,
    required this.onTap,
  });

  final String number;
  final String san;
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
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Text.rich(
            style: PgnTextStyles.moveAt(1).copyWith(height: 1.4),
            TextSpan(
              children: [
                TextSpan(
                  text: number.isEmpty ? '' : '$number ',
                  style: AppTextStyles.monoDense.copyWith(color: AppColors.ink),
                ),
                TextSpan(
                  text: san,
                  style: PgnTextStyles.moveAt(1).copyWith(
                    height: 1.4,
                    color: AppColors.ink,
                    fontWeight: FontWeight.w600,
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

class _TableRules extends StatelessWidget {
  const _TableRules({required this.controller});

  final BughouseController controller;

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    final derived = controller.deriveTimeAdvantageFromClocks;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const BughousePanelLabel('You play on Board 1'),
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
        const BughousePanelLabel('Your team’s clock advantage'),
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
            'Use the board clocks',
            style: AppTextStyles.caption,
          ),
        ),
        if (derived)
          const Text(
            'Both diagonal clock pairs must agree by more than 5 seconds. Mixed clocks use Level; clocks do not run in this model.',
            style: AppTextStyles.muted,
          ),
        const SizedBox(height: 4),

        const BughousePanelLabel('Require a move'),
        SegmentedButton<RequireMoveOn>(
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          segments: const [
            ButtonSegment(
              value: RequireMoveOn.none,
              label: Text('Allow sitting'),
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
        Tooltip(
          message:
              'See how the best moves and your team’s evaluation change '
              'in this position when:\n'
              '• Your team is ahead on time and may wait (sit).\n'
              '• Your team is level or behind on time.\n'
              '• Your team must move on Board 1.\n'
              'Results open in the Engine tab under Clock scenarios. '
              'Your clocks and position stay the same.',
          child: OutlinedButton.icon(
            icon: const Icon(Icons.compare_arrows, size: 16),
            label: const Text('Compare clock scenarios'),
            onPressed: controller.isComparing
                ? null
                : controller.compareScenarios,
          ),
        ),
      ],
    );
  }
}

class _EngineSection extends StatelessWidget {
  const _EngineSection({required this.controller});
  final BughouseController controller;

  @override
  Widget build(BuildContext context) {
    final settings = controller.engineSettings;
    Widget number(
      String label,
      int value,
      int min,
      int max,
      ValueChanged<int> change, {
      String? suffix,
      String? hint,
    }) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Tooltip(
              message: hint ?? label,
              child: Text(label, style: AppTextStyles.body),
            ),
          ),
          NumberStepper(
            key: ValueKey('bughouse-setting-$label'),
            value: value,
            min: min,
            max: max,
            onChanged: change,
            suffix: suffix,
          ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (BughouseCpuLimit.supported)
          number(
            'CPU cores',
            settings.cores.clamp(1, BughouseCpuLimit.available),
            1,
            BughouseCpuLimit.available,
            (v) => controller.setEngineSettings(settings.copyWith(cores: v)),
            hint: 'Maximum CPU cores available to analysis',
          ),
        if (!BughouseCpuLimit.supported)
          const Text(
            'CPU cores: managed by this engine build',
            style: AppTextStyles.muted,
          ),
        number(
          'Lines',
          settings.lines,
          BughouseEngineSettings.linesMin,
          BughouseEngineSettings.linesMax,
          (v) => controller.setEngineSettings(settings.copyWith(lines: v)),
        ),
        number(
          'Memory',
          settings.hashMb,
          BughouseEngineSettings.hashMin,
          BughouseEngineSettings.hashMax,
          (v) => controller.setEngineSettings(settings.copyWith(hashMb: v)),
          suffix: 'MB',
        ),
        number(
          'Time per pass',
          settings.thinkSeconds,
          BughouseEngineSettings.thinkMin,
          BughouseEngineSettings.thinkMax,
          (v) =>
              controller.setEngineSettings(settings.copyWith(thinkSeconds: v)),
          suffix: 's',
        ),
        number(
          'Batch size',
          settings.batchSize,
          BughouseEngineSettings.batchMin,
          BughouseEngineSettings.batchMax,
          (v) => controller.setEngineSettings(settings.copyWith(batchSize: v)),
          hint: 'Positions evaluated together by the network',
        ),
      ],
    );
  }
}

/// A message, and — when the failure came with a diagnostic — one button that
/// puts the whole thing on the clipboard.
///
/// The button exists because of how these failures are actually resolved: the
/// person who hits one is not the person who can read it, so what matters is
/// that they can hand it over without having to understand or retype any of
/// it. The details stay collapsed, because they are pages long and nobody
/// reading the banner wants them on screen; copying does not require opening
/// them.
class _Banner extends StatefulWidget {
  const _Banner({
    required this.message,
    required this.isError,
    this.details,
    this.helpUrl,
  });

  final String message;
  final bool isError;

  /// The full report, or null when the failure had nothing more to say.
  final String? details;

  /// Something to install that would fix this, when the failure named one.
  /// Offered as a button rather than left in the text, because the whole
  /// difference between a user who fixes this and one who gives up is whether
  /// the next step is a click or a URL to retype.
  final String? helpUrl;

  @override
  State<_Banner> createState() => _BannerState();
}

class _BannerState extends State<_Banner> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final foreground = widget.isError
        ? scheme.onErrorContainer
        : scheme.onSurfaceVariant;
    final details = widget.details;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: widget.isError
            ? scheme.errorContainer
            : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(
            widget.message,
            style: AppTextStyles.caption.copyWith(color: foreground),
          ),
          if (widget.helpUrl case final url?) ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('bughouse-install-runtime'),
                onPressed: () => unawaited(launchUrl(Uri.parse(url))),
                style: TextButton.styleFrom(
                  foregroundColor: foreground,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                icon: const Icon(Icons.download_outlined, size: 14),
                label: Text(
                  'Download the Microsoft runtime',
                  style: AppTextStyles.caption.copyWith(color: foreground),
                ),
              ),
            ),
          ],
          if (details != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                CopyButton(
                  key: const Key('bughouse-copy-diagnostics'),
                  label: 'Copy diagnostics',
                  foreground: foreground,
                  dense: true,
                  text: () => '${widget.message}\n\n$details',
                ),
                const SizedBox(width: 4),
                TextButton(
                  key: const Key('bughouse-toggle-diagnostics'),
                  onPressed: () => setState(() => _expanded = !_expanded),
                  style: TextButton.styleFrom(
                    foregroundColor: foreground,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    _expanded ? 'Hide details' : 'Show details',
                    style: AppTextStyles.caption.copyWith(color: foreground),
                  ),
                ),
              ],
            ),
            Text(
              'Send this to whoever is looking at the bug — it names every '
              'file, its size and where the engine looked for it.',
              style: AppTextStyles.caption.copyWith(
                color: foreground.withValues(alpha: 0.75),
              ),
            ),
            if (_expanded) ...[
              const SizedBox(height: 8),
              // Bounded and separately scrollable: the report is longer than
              // the panel and the eval above it must not be pushed away.
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: scheme.surface,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: SingleChildScrollView(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SelectableText(
                        details,
                        style: AppTextStyles.monoDense,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// Progress and labeled what-if results for the current position.
class _ScenarioTable extends StatelessWidget {
  const _ScenarioTable({required this.controller});

  final BughouseController controller;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('bughouse-clock-scenarios'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.divider),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('Clock scenarios', style: AppTextStyles.bodyStrong),
              ),
              if (controller.isComparing)
                const SizedBox(
                  key: ValueKey('bughouse-clock-progress'),
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            controller.isComparing
                ? 'Comparing… ${controller.scenarios.length} of 3 ready'
                : controller.scenarios.length == 3
                ? 'Comparison complete'
                : 'Comparison stopped · ${controller.scenarios.length} of 3 ready',
            style: AppTextStyles.caption,
          ),
          const SizedBox(height: 4),
          const Text(
            'What-if results · scores for your team',
            style: AppTextStyles.caption,
          ),
          for (final row in controller.scenarios) ...[
            const Divider(height: 16),
            Row(
              children: [
                Expanded(child: Text(row.label, style: AppTextStyles.body)),
                Text(row.eval?.label ?? '—', style: AppTextStyles.mono),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              row.best == null ? 'No move available' : _moves(row.best!),
              style: PgnTextStyles.moveAt(
                1,
              ).copyWith(color: AppColors.ink, fontWeight: FontWeight.w600),
            ),
          ],
        ],
      ),
    );
  }

  String _moves(BughouseJointMove action) {
    final seats = controller.describeSeats(action, team: controller.state.team);
    return seats.isEmpty
        ? 'No move available'
        : seats
              .map((seat) => '${seat.board.label}: ${seat.move}')
              .join('   ·   ');
  }
}

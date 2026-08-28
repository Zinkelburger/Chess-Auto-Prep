import 'package:flutter/material.dart';

import '../../../models/engine_settings.dart';
import '../../tactics/services/mining_settings.dart';
import '../../tactics/services/tactics_import_coordinator.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../utils/system_info.dart';
import '../../../widgets/labeled_toggle.dart';
import '../services/home_review_runner.dart';

/// The tactics home's three buttons in one column, plus the progress they share
/// and — in plain sight rather than behind a gear — how much of the machine the
/// engine is allowed to use.
///
/// Design rules this encodes:
///
/// * **One job button, then two places to go.** The top button is the *engine
///   analysis*: it downloads games and grinds Stockfish over them, which is the
///   only thing here that takes minutes and every core. Under a rule, Study
///   tactics and Opening review are the two ways to spend what that analysis
///   produced — puzzles from your blunders, leaks in your book. The rule and
///   the filled green fill say which of the two groups a button is in; three
///   near-identical buttons in a stack read as one undifferentiated menu.
/// * **The vocabulary keeps them apart.** The top button says "analysis" and
///   never "review", because *Opening review* is one of the buttons below it.
///   (It used to read "Resume review", one word away from "Opening review".)
/// * **It starts itself.** Setting a username is the opt-in: once the list has
///   games, the run begins (see [GamesListFilters.autoRun]). A home screen
///   where nothing has happened until you find the right gray button is a
///   screen that looks broken. Auto-start is a checkbox on this strip for
///   anyone who wants the old behaviour, and turning it off sticks.
/// * **Pause is the same button, and there is no cancel.** A run you can stop
///   and carry on is one control with two states; nothing you have already
///   waited for is ever thrown away.
/// * **The button says what pressing it will do.** Not a fixed verb with the
///   real state hidden in a caption: with games downloaded but not yet analysed
///   it reads "Resume engine analysis", because that is the situation the user
///   is in. The *count* of waiting work is not in the button — it is the
///   headline right beside it ("12 unanalysed games"), so the button stays
///   short. The two result buttons below still carry their counts.
/// * **The job button asks to be pressed when there is work.** With unanalysed
///   games waiting and nothing running, it is green and breathes — a slow
///   glow, stopped for anyone who has asked the system for reduced motion. It
///   goes back to gray the moment there is nothing to do but check for new
///   games, and amber while running, as Pause. It was gray in every state,
///   on the theory that a control costing minutes of CPU should not beg; the
///   result was that the one thing to press looked like scenery.
/// * **Cores and depth are stated, not steppered.** How much of the laptop goes
///   away and how long the wait is belong on screen, but as a sentence you read
///   in passing; changing them is a trip to the strip's one gear.
/// * **Auto-start is on the strip, not behind the gear.** Whether the analysis
///   starts itself when the app opens is the one setting users toggle often
///   enough to want in reach; the checkbox sits with the refresh and gear
///   buttons and its hover tooltip says what it spends. The gear keeps what is left:
///   which games, and how hard the engine works.
/// * **Static.** Every control is always present; only labels, the enabled
///   states and the progress bar change.
class ReviewStrip extends StatelessWidget {
  const ReviewStrip({
    super.key,
    required this.runner,
    required this.coordinator,
    required this.isLoadingGames,
    required this.gamesInWindow,
    required this.unreviewedCount,
    required this.windowLabel,
    required this.readyPuzzleCount,
    required this.openingIssueCount,
    required this.autoRun,
    required this.onAutoRunChanged,
    required this.onStart,
    required this.onPause,
    required this.onStudyTactics,
    required this.onRefresh,
    required this.onSettings,
    required this.onOpeningReview,
  });

  /// Width of the button column. Fixed so the three buttons are the same size
  /// and the status beside them starts at the same x in every state. Wide
  /// enough for the longest transport label ("Resume engine analysis")
  /// without ellipsis.
  static const double _buttonWidth = 250;

  final HomeReviewRunner runner;

  /// Source of the per-game progress while the engine pass runs.
  final TacticsImportCoordinator coordinator;

  final bool isLoadingGames;
  final int gamesInWindow;

  /// Games in the window with no mistake counts yet — the work the play button
  /// is offering to do.
  final int unreviewedCount;

  final String windowLabel;

  /// Puzzles the saved practice filters would queue up right now — the number
  /// on the Study-tactics button, and what decides whether it is pressable.
  final int readyPuzzleCount;

  /// Distinct opening leaks (mistakes + book ends) across the window — the
  /// number on the Opening-review button. Zero is still openable: the dialog
  /// is also where "no book was designated for this game" gets explained.
  final int openingIssueCount;

  /// Whether the analysis starts itself when the app opens — the checkbox in
  /// the icon row. Persisted with the list filters.
  final bool autoRun;
  final ValueChanged<bool> onAutoRunChanged;

  final VoidCallback onStart;
  final VoidCallback onPause;
  final VoidCallback onStudyTactics;
  final VoidCallback onRefresh;
  final VoidCallback onSettings;
  final VoidCallback onOpeningReview;

  @override
  Widget build(BuildContext context) {
    final running = runner.isRunning;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 6),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.divider)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: _buttonWidth,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildTransportButton(running),
                    // The rule is the whole point of the layout: above it, the
                    // engine job; below it, the two things to do with its
                    // results.
                    const SizedBox(height: 12),
                    const Divider(
                      height: 1,
                      thickness: 1,
                      color: AppColors.divider,
                    ),
                    const SizedBox(height: 12),
                    _buildStudyButton(),
                    const SizedBox(height: 6),
                    _buildOpeningReviewButton(),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(child: _buildStatus(running)),
              // Plain hover tooltip, not an ⓘ: a glyph beside a checkbox on
              // the strip is one more thing to look at, and the explanation is
              // one hover away either way.
              Tooltip(
                message:
                    'Start the engine analysis by itself as soon as there are '
                    'games to analyse. On by default; it puts your CPU cores '
                    'on Stockfish for several minutes. Uncheck to start every '
                    'run by hand.',
                child: AppCheckbox(
                  label: 'Auto-start',
                  value: autoRun,
                  onChanged: onAutoRunChanged,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh, size: 18),
                tooltip: 'Download my games again, without analysing them',
                visualDensity: VisualDensity.compact,
                onPressed: isLoadingGames || running ? null : onRefresh,
              ),
              IconButton(
                icon: const Icon(Icons.settings, size: 18),
                tooltip: 'Analysis settings…',
                visualDensity: VisualDensity.compact,
                onPressed: onSettings,
              ),
            ],
          ),
          const SizedBox(height: 6),
          _buildProgressBar(running),
          const SizedBox(height: 6),
          const _EngineLoadRow(),
        ],
      ),
    );
  }

  /// Whether pressing play carries on work already part-done — either the run
  /// was paused this session, or the app was closed with games downloaded and
  /// only some of them analysed. The second case is the common one and used to
  /// read "Review games", as though nothing had happened.
  bool get _isResume =>
      runner.canResume ||
      (unreviewedCount > 0 && unreviewedCount < gamesInWindow);

  /// What pressing the button will do, in the button. Always "analysis", never
  /// "review" — see the class doc. No count in the label: the headline beside
  /// the button carries it ("12 unanalysed games").
  String _transportLabel(bool running) {
    if (running) return 'Pause';
    if (unreviewedCount > 0) {
      return _isResume ? 'Resume engine analysis' : 'Start engine analysis';
    }
    return gamesInWindow > 0 ? 'Check for new games' : 'Start engine analysis';
  }

  /// The job: the one control here that costs minutes and every core, so the
  /// one control here that is filled and a size larger than the rest.
  Widget _buildTransportButton(bool running) {
    final enabled = running || runner.hasAnySource;
    return _TransportButton(
      label: _transportLabel(running),
      running: running,
      enabled: enabled,
      // Green and breathing only when pressing it would actually do work:
      // games waiting to be analysed, or nothing downloaded yet.
      attention:
          !running && enabled && (unreviewedCount > 0 || gamesInWindow == 0),
      tooltip: runner.hasAnySource
          ? (running
                ? 'Stop after the game being analysed; press again to carry on'
                : _isResume
                ? 'Carry on with the $unreviewedCount '
                      '${_games(unreviewedCount)} that have not been analysed '
                      'yet. Nothing already analysed is repeated, and no games '
                      'are downloaded again.'
                : 'Download your $windowLabel, run Stockfish over them, and '
                      'check them against your books')
          : 'Set a username first',
      onPressed: enabled ? (running ? onPause : onStart) : null,
    );
  }

  /// What the analysis produced, part one: the puzzles from your blunders.
  /// Outlined and a size smaller than the job above it — pressing it costs
  /// nothing and starts nothing in the background.
  Widget _buildStudyButton() {
    final ready = readyPuzzleCount > 0;
    return Tooltip(
      message: ready
          ? 'Play the $readyPuzzleCount '
                '${readyPuzzleCount == 1 ? 'puzzle' : 'puzzles'} your filters '
                'let through'
          : 'No puzzles ready — analyse your games first, or loosen the '
                'filters on the right',
      child: _SecondaryButton(
        buttonKey: const Key('study-tactics-button'),
        icon: Icons.extension,
        label: ready ? 'Study tactics ($readyPuzzleCount)' : 'Study tactics',
        onPressed: ready ? onStudyTactics : null,
      ),
    );
  }

  /// Part two: every place your openings left the book, as one queue.
  ///
  /// Pressable with nothing to show, unlike Study tactics, because "no leaks"
  /// and "no book designated for these games" look identical from out here and
  /// only the dialog can tell you which one you are looking at.
  Widget _buildOpeningReviewButton() {
    final hasIssues = openingIssueCount > 0;
    return Tooltip(
      message: hasIssues
          ? 'Review the $openingIssueCount '
                '${openingIssueCount == 1 ? 'place' : 'places'} your '
                '$windowLabel left your books, grouped by line'
          : 'Check your $windowLabel against your books',
      child: _SecondaryButton(
        buttonKey: const Key('opening-review-button'),
        icon: Icons.menu_book,
        label: hasIssues
            ? 'Opening review ($openingIssueCount)'
            : 'Opening review',
        onPressed: gamesInWindow > 0 ? onOpeningReview : null,
      ),
    );
  }

  Widget _buildStatus(bool running) {
    final stage = runner.stage;
    final failed = stage == HomeReviewStage.failed;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _headline(running),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTextStyles.body.copyWith(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: failed ? AppColors.danger : AppColors.ink,
          ),
        ),
        SizedBox(
          height: 17,
          child: Text(
            _detailLine(running),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.body.copyWith(
              fontSize: 12.5,
              color: failed ? AppColors.danger : AppColors.onSurfaceSoft,
            ),
          ),
        ),
      ],
    );
  }

  /// The state of the analysis in one short phrase — the thing you read first.
  ///
  /// Not-yet-analysed games are always the headline when there are any: this
  /// screen exists to get them analysed, so it should say so rather than making
  /// you infer it from a game count.
  String _headline(bool running) {
    final stage = runner.stage;
    if (!runner.hasAnySource) return 'No account set';
    if (running) {
      if (stage == HomeReviewStage.reviewing && coordinator.gamesTotal > 0) {
        return 'Analysing game ${coordinator.gamesDone} of '
            '${coordinator.gamesTotal}';
      }
      return stage.label;
    }
    if (stage == HomeReviewStage.failed) return 'Analysis failed';
    if (stage == HomeReviewStage.paused) {
      return unreviewedCount > 0
          ? 'Paused — $unreviewedCount ${_games(unreviewedCount)} left'
          : 'Paused';
    }
    if (unreviewedCount > 0) {
      return '$unreviewedCount unanalysed ${_games(unreviewedCount)}';
    }
    if (gamesInWindow == 0) return 'No games yet';
    // "No new games to analyse" answered a question nobody asked (what came
    // back from the last check) instead of the one they did: is my window
    // analysed? It is, and this says how much of it.
    return 'Finished analysing $gamesInWindow ${_games(gamesInWindow)}';
  }

  /// The supporting line under the headline.
  String _detailLine(bool running) {
    if (runner.stage == HomeReviewStage.failed) {
      return runner.detail ?? 'Something went wrong';
    }
    if (!runner.hasAnySource) {
      return 'Add a Lichess or Chess.com username on the right';
    }
    if (running) {
      final found = coordinator.newPositionsFound;
      final site = runner.detail;
      return [
        ?site,
        '$found ${found == 1 ? 'puzzle' : 'puzzles'} found',
      ].join(' · ');
    }
    // Stopped mid-run, the question is "what did I lose". Nothing: every game
    // already analysed keeps its counts, and Resume starts at the next one
    // without re-downloading anything.
    if (runner.stage == HomeReviewStage.paused) {
      return 'Press Resume to carry on where it stopped';
    }
    if (gamesInWindow == 0) {
      return 'Press Start engine analysis to download them';
    }
    // No "Out of 20 in your last 20 games" line: the headline already counts
    // the work, and restating the window read as a fact without a use.
    if (unreviewedCount > 0) return '';
    // "last 20 games" takes a plural verb, "last 1 game" does not.
    final verb = windowLabel.endsWith('s') ? 'are' : 'is';
    return 'Your $windowLabel $verb downloaded and analysed';
  }

  static String _games(int n) => n == 1 ? 'game' : 'games';

  /// Determinate while the engine pass reports games, indeterminate during the
  /// download (whose length nobody knows), and an empty track otherwise — so
  /// the strip never changes height.
  Widget _buildProgressBar(bool running) {
    final showBar = running || isLoadingGames;
    final determinate =
        running &&
        runner.stage == HomeReviewStage.reviewing &&
        coordinator.gamesTotal > 0;
    return SizedBox(
      height: 3,
      child: showBar
          ? LinearProgressIndicator(
              minHeight: 3,
              value: determinate ? coordinator.progressFraction : null,
            )
          : const ColoredBox(color: AppColors.divider),
    );
  }
}

/// The two buttons below the rule, which have to be identical to each other and
/// visibly lighter than the job button above it: same outline, same height,
/// same type size, only the icon and the label differ.
/// The strip's job button, in three moods: gray when there is nothing much to
/// do, green and slowly glowing when work is waiting, amber while running.
///
/// The glow is a shadow, not a scale or a size change — the strip's button
/// column is a fixed width and the two buttons under it must not move while
/// this one breathes. It stops entirely when the platform asks for reduced
/// motion, and whenever the button is not the thing to press.
class _TransportButton extends StatefulWidget {
  const _TransportButton({
    required this.label,
    required this.tooltip,
    required this.running,
    required this.enabled,
    required this.attention,
    required this.onPressed,
  });

  final String label;
  final String tooltip;
  final bool running;
  final bool enabled;

  /// Whether pressing it right now would actually start work.
  final bool attention;

  final VoidCallback? onPressed;

  @override
  State<_TransportButton> createState() => _TransportButtonState();
}

class _TransportButtonState extends State<_TransportButton>
    with SingleTickerProviderStateMixin {
  static const _shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(10)),
  );

  /// Half-cycles of glow when work appears. A burst, not a permanent
  /// animation: it is there to catch the eye on arrival, and a control that
  /// pulses forever is both a battery cost and, after ten seconds, wallpaper.
  /// (It also keeps every `pumpAndSettle` in the test suite terminating.)
  static const _burstCycles = 5;

  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..addStatusListener(_onPulseStatus);

  int _cyclesLeft = 0;

  bool _startedOnce = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Not initState: the burst asks MediaQuery whether animation is wanted,
    // and inherited widgets are off-limits until here.
    if (widget.attention && !_startedOnce) {
      _startedOnce = true;
      _startBurst();
    }
  }

  @override
  void didUpdateWidget(_TransportButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Restart on every fresh arrival of work — a paused run that still has
    // games waiting should ask again, not sit there gray-green and silent.
    if (widget.attention && !oldWidget.attention) {
      _startedOnce = true;
      _startBurst();
    } else if (!widget.attention && oldWidget.attention) {
      _startedOnce = false;
      _stopBurst();
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  void _startBurst() {
    if (MediaQuery.disableAnimationsOf(context)) return;
    _cyclesLeft = _burstCycles;
    _pulse.forward(from: 0);
  }

  void _stopBurst() {
    _cyclesLeft = 0;
    _pulse.stop();
    _pulse.value = 0;
  }

  void _onPulseStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      _pulse.reverse();
    } else if (status == AnimationStatus.dismissed && _cyclesLeft > 1) {
      _cyclesLeft--;
      _pulse.forward();
    }
  }

  @override
  Widget build(BuildContext context) {
    final background = widget.running
        ? AppColors.warningSurface
        : widget.attention
        ? AppColors.successSurface
        : AppColors.surfaceInset;

    final button = FilledButton.icon(
      key: const Key('review-transport-button'),
      onPressed: widget.onPressed,
      icon: Icon(widget.running ? Icons.pause : Icons.play_arrow, size: 22),
      label: Text(
        widget.label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        backgroundColor: background,
        foregroundColor: AppColors.ink,
        shape: _shape,
      ),
    );

    return Tooltip(
      message: widget.tooltip,
      child: widget.attention
          ? AnimatedBuilder(
              animation: _pulse,
              builder: (context, child) {
                final t = _pulse.value;
                return DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: _shape.borderRadius,
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.accent.withValues(
                          alpha: 0.16 + 0.30 * t,
                        ),
                        blurRadius: 6 + 16 * t,
                        spreadRadius: 0.5 + 1.5 * t,
                      ),
                    ],
                  ),
                  child: child,
                );
              },
              child: button,
            )
          : button,
    );
  }
}

class _SecondaryButton extends StatelessWidget {
  const _SecondaryButton({
    required this.buttonKey,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final Key buttonKey;
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      key: buttonKey,
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13.5),
      ),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        foregroundColor: AppColors.ink,
        side: const BorderSide(color: AppColors.outline),
      ),
    );
  }
}

/// How hard the analysis is allowed to work, in one sentence. The two numbers
/// were `− 4 of 8 +` steppers until they were read back as a wall of tiny
/// buttons; they are a statement now, and the editing lives with everything
/// else about the review, behind the strip's gear.
class _EngineLoadRow extends StatelessWidget {
  const _EngineLoadRow();

  @override
  Widget build(BuildContext context) {
    final engine = EngineSettings.instance;
    final mining = MiningSettings.instance;
    final maxCores = getLogicalCores();
    return ListenableBuilder(
      listenable: Listenable.merge([engine, mining]),
      builder: (context, _) => Row(
        children: [
          const Icon(Icons.memory, size: 14, color: AppColors.onSurfaceMuted),
          const SizedBox(width: 6),
          // Flexible, not a fixed Text: this row sits in a pane whose width is
          // half a window, and a line that overflows is worse than one that
          // ellipsizes.
          Flexible(
            child: Tooltip(
              message: 'Change these in Analysis settings — the gear above',
              child: Text(
                'Analysis uses ${engine.workers} of $maxCores CPU cores, '
                'at engine depth ${mining.depth}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.body.copyWith(
                  fontSize: 12.5,
                  color: AppColors.onSurfaceSoft,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

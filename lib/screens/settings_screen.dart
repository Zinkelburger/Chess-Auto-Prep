/// Centralized settings screen accessible from the app bar.
///
/// Holds machine-level configuration only: who you are (Lichess login, chess
/// usernames), which repertoires are your books, how much of the machine the
/// engine may use, and the offline eval database. Analysis *behavior* lives on
/// the gear next to each analysis surface — see stockfish_settings_dialog.dart,
/// expectimax_settings_dialog.dart, and analysis_panels_dialog.dart — so every
/// knob sits where its effect is visible.
///
/// Two rules this screen keeps to, both learned the hard way:
/// - **No state toggles.** Turning the engine on/off is not configuration, it
///   is an action with a visible result; it belongs on the ⚡ button by the
///   board, not buried in a settings list.
/// - **No sliders.** A slider reads as a scrollbar, hides its value until
///   dragged, and turns "give it one more core" into a pixel-hunt. Numbers get
///   −/+ steppers, short lists get dropdowns.
///
/// Uses [ListenableBuilder] so it always reflects the latest singleton state,
/// even if another UI surface mutates [EngineSettings] concurrently.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/app_state.dart';
import '../features/games/widgets/my_repertoires_section.dart';
import '../models/engine_settings.dart';
import '../models/eval_database_settings.dart';
import '../theme/app_text_styles.dart';
import '../utils/app_messages.dart';
import '../utils/system_info.dart';
import '../widgets/common/confirm_dialog.dart';
import '../widgets/labeled_toggle.dart';
import '../widgets/settings/account_settings_section.dart';
import '../widgets/settings/settings_widgets.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static final _projectUri = Uri.parse(
    'https://github.com/Zinkelburger/Chess-Auto-Prep',
  );

  final _engine = EngineSettings.instance;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _engine,
      builder: (context, _) {
        final cores = getLogicalCores();

        return Scaffold(
          appBar: AppBar(
            title: const Text('Settings'),
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => Navigator.pop(context),
            ),
          ),
          // The ListView is the body so it gets the scaffold's bounded
          // height and actually scrolls. Wrapping it in Align first gave it
          // unbounded height: it grew to fit every section, the scaffold
          // clipped the overflow, and everything below the fold (engine,
          // database, agent bridge) was unreachable.
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'Settings for this machine. Search depth, number of lines, '
                        'expectimax tuning and panel visibility live on the gear '
                        '(⚙) next to each analysis panel instead, where you can '
                        'see what they change.',
                        style: AppTextStyles.caption,
                      ),

                      // ── Who you are ──────────────────────────────
                      const ChessUsernamesSection(),
                      const LichessLoginSection(),

                      // ── My repertoires ───────────────────────────
                      const MyRepertoiresSection(),

                      // ── Engine ───────────────────────────────────
                      _buildEngineSection(cores),

                      // ── Databases ────────────────────────────────
                      _buildDatabasesSection(),

                      // ── About ────────────────────────────────────
                      _buildAboutSection(),

                      // ── Reset ────────────────────────────────────
                      const SizedBox(height: 24),
                      _buildResetButton(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _openProject() async {
    var opened = false;
    try {
      opened = await launchUrl(
        _projectUri,
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      opened = false;
    }
    if (!opened && mounted) {
      showAppSnackBar(
        context,
        'Could not open the Chess Auto Prep GitHub page',
        isError: true,
      );
    }
  }

  Widget _buildAboutSection() {
    return SettingsGroup(
      title: 'About & open source',
      icon: Icons.info_outline,
      subtitle:
          'Chess Auto Prep is open source. Follow development, report an '
          'issue, or inspect the software and third-party licenses.',
      children: [
        ListTile(
          leading: SizedBox.square(
            dimension: 22,
            child: SvgPicture.asset('assets/icons/github-mark-white.svg'),
          ),
          title: const Text('Chess Auto Prep on GitHub'),
          subtitle: const Text('Source code, releases, and issue tracker'),
          trailing: const Icon(Icons.open_in_new, size: 17),
          onTap: () => unawaited(_openProject()),
        ),
        const Divider(height: 1, indent: 16, endIndent: 16),
        ListTile(
          leading: const Icon(Icons.balance_outlined, size: 22),
          title: const Text('Open-source licenses'),
          subtitle: const Text(
            'Includes Hivemind by aminwoo, the MIT-licensed bughouse engine',
          ),
          trailing: const Icon(Icons.chevron_right, size: 20),
          onTap: () => showLicensePage(
            context: context,
            applicationName: 'Chess Auto Prep',
          ),
        ),
      ],
    );
  }

  // ── Engine section ─────────────────────────────────────────────────────────

  Widget _buildEngineSection(int cores) {
    return SettingsGroup(
      title: 'Engine power',
      icon: Icons.bolt,
      // No on/off switch here on purpose: starting and stopping Stockfish is
      // an action you want to see the result of, so it lives on the ⚡ button
      // next to the board.
      subtitle:
          'How much of this computer Stockfish may use. Turn the engine on and '
          'off with the ⚡ button next to the board.',
      children: [
        SettingsStepperTile(
          label: 'Parallel workers for bulk analysis',
          description:
              'Runs one Stockfish process per worker: 1 CPU thread and '
              '128 MB hash each, plus engine memory. More workers analyse '
              'independent positions faster; fewer use less memory and leave '
              'the computer freer.',
          value: _engine.workers,
          min: 1,
          max: cores,
          suffix: 'of $cores cores',
          onChanged: (v) => _engine.workers = v,
        ),
        SettingsStepperTile(
          label: 'Threads for one board engine',
          description:
              'The engine bar uses one Stockfish process with this many CPU '
              'threads. This is best for one position; bulk analysis uses '
              'the parallel workers above.',
          value: _engine.inlineThreads,
          min: 1,
          max: cores,
          suffix: 'of $cores cores',
          onChanged: (v) => _engine.inlineThreads = v,
        ),
        SettingsChoiceTile<int>(
          label: 'Human-opponent strength (Maia)',
          description:
              'The rating the app assumes your opponents play at when it '
              'guesses which reply a human would pick.',
          value: _engine.maiaElo.clamp(600, 2400) ~/ 100 * 100,
          items: [
            for (var elo = 600; elo <= 2400; elo += 100) (elo, '$elo Elo'),
          ],
          onChanged: (v) => _engine.maiaElo = v,
        ),
      ],
    );
  }

  // ── Databases section ──────────────────────────────────────────────────────

  /// A pointer, not a panel.
  ///
  /// Master games, your own games and the two offline evaluation stores each
  /// had a section here, and between them they filled more of this screen than
  /// everything else put together — while still not answering "how much disk
  /// is this using", because no section could see the others. They live on the
  /// Databases page now (Ctrl+9). What stays is the one switch that is a
  /// preference about *this machine's* network use rather than a fact about a
  /// store on its disk.
  Widget _buildDatabasesSection() {
    return SettingsGroup(
      title: 'Databases',
      icon: Icons.storage,
      subtitle:
          'Master games, your own games, and the offline evaluation stores — '
          'what is downloaded, how much disk it uses, and how to refresh it.',
      children: [
        ListTile(
          leading: const Icon(Icons.dns_outlined, size: 22),
          title: const Text('Open Databases'),
          subtitle: const Text(
            'Everything the app keeps on this machine, on one page',
          ),
          trailing: const Icon(Icons.chevron_right, size: 20),
          // Settings is a pushed route over the mode host, so switching mode
          // without popping would change the screen underneath and leave the
          // user still looking at Settings.
          onTap: () {
            final appState = context.read<AppState>();
            Navigator.pop(context);
            appState.setMode(AppMode.databases);
          },
        ),
        const Divider(height: 1, indent: 16, endIndent: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: ListenableBuilder(
            listenable: EvalDatabaseSettings.instance,
            builder: (context, _) {
              final settings = EvalDatabaseSettings.instance;
              return AppSwitch(
                label: 'Use the ChessDB API for on-demand expectimax',
                value: settings.chessDbApiForExpectimax,
                onChanged: (v) =>
                    unawaited(settings.setChessDbApiForExpectimax(v)),
                tooltip:
                    'A probe started from the expectimax pane may query '
                    'chessdb.cn for evaluations. Off by default: one probe '
                    'from a busy position can use most of the daily quota, '
                    'and a local dump or the engine answers just as well. '
                    'Repertoire builds have their own switch on the Generate '
                    'form.',
              );
            },
          ),
        ),
      ],
    );
  }

  // ── Reset button ───────────────────────────────────────────────────────────

  /// Put every engine, analysis and database setting back to its default.
  ///
  /// The reset runs after the dialog closes rather than inside its button, so
  /// the await is not racing a widget that is being torn down.
  Future<void> _confirmResetToDefaults() async {
    final confirmed = await confirmAction(
      context,
      title: 'Reset Settings',
      message:
          'Reset all engine, analysis, and database settings to '
          'factory defaults?',
      confirmLabel: 'Reset',
    );
    if (!confirmed) return;
    _engine.resetToDefaults();
    await EvalDatabaseSettings.instance.resetToDefaults();
  }

  Widget _buildResetButton() {
    return Center(
      child: OutlinedButton.icon(
        icon: const Icon(Icons.restore, size: 16),
        label: const Text('Reset All to Defaults'),
        onPressed: () => unawaited(_confirmResetToDefaults()),
      ),
    );
  }
}

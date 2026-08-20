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
import 'package:provider/provider.dart';

import '../features/games/widgets/my_repertoires_section.dart';
import '../models/engine_settings.dart';
import '../models/eval_database_settings.dart';
import '../theme/app_text_styles.dart';
import '../utils/system_info.dart';
import '../widgets/eval_database_settings_panel.dart';
import '../widgets/master_games_settings_panel.dart';
import '../widgets/games_database_settings_panel.dart';
import '../services/master_games/master_games_service.dart';
import '../widgets/settings/account_settings_section.dart';
import '../widgets/settings/settings_widgets.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
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
                      Text(
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

                      // ── Master games ─────────────────────────────
                      Builder(
                        builder: (context) {
                          context.watch<MasterGamesService>();
                          return _buildMasterGamesSection();
                        },
                      ),

                      // ── Your games ───────────────────────────────
                      _buildGamesDatabaseSection(),

                      // ── Database ─────────────────────────────────
                      Builder(
                        builder: (context) {
                          context.watch<EvalDatabaseSettings>();
                          return _buildDatabaseSection();
                        },
                      ),

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
          label: 'Engine copies for analysis',
          description:
              'More copies analyze games and build repertoires faster, but '
              'leave less of the machine for everything else.',
          value: _engine.workers,
          min: 1,
          max: cores,
          suffix: 'of $cores cores',
          onChanged: (v) => _engine.workers = v,
        ),
        SettingsStepperTile(
          label: 'Threads for the board engine bar',
          description:
              'Used by the single engine readout under the board in the PGN '
              'viewer and study.',
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

  // ── Master games section ───────────────────────────────────────────────────

  Widget _buildMasterGamesSection() {
    return const SettingsGroup(
      title: 'Master games database',
      icon: Icons.library_books_outlined,
      subtitle:
          'Titled-player games from The Week in Chess, stored locally so '
          'repertoires are built on master practice: opponent replies, model '
          'games, and "improves on … in <game>" notes.',
      children: [MasterGamesSettingsPanel()],
    );
  }

  // ── Your games section ─────────────────────────────────────────────────────

  Widget _buildGamesDatabaseSection() {
    return const SettingsGroup(
      title: 'Your games database',
      icon: Icons.inventory_2_outlined,
      subtitle:
          'Every game the app downloads or imports — Player Analysis, the '
          'home games library, the tactics archive — parsed once into a local '
          'database with indexed players, dates and opening positions.',
      children: [GamesDatabaseSettingsPanel()],
    );
  }

  // ── Database section ───────────────────────────────────────────────────────

  Widget _buildDatabaseSection() {
    return const SettingsGroup(
      title: 'Offline evaluation database',
      icon: Icons.storage,
      subtitle:
          'Optional. A local copy of ChessDB answers "how good is this '
          'position?" instantly, so the engine only runs for positions nobody '
          'has looked at yet.',
      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: EvalDatabaseSettingsPanel(),
        ),
      ],
    );
  }

  // ── Reset button ───────────────────────────────────────────────────────────

  Widget _buildResetButton() {
    return Center(
      child: OutlinedButton.icon(
        icon: const Icon(Icons.restore, size: 16),
        label: const Text('Reset All to Defaults'),
        onPressed: () {
          unawaited(
            showDialog(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('Reset Settings'),
                content: const Text(
                  'Reset all engine, analysis, and database settings to '
                  'factory defaults?',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Cancel'),
                  ),
                  TextButton(
                    onPressed: () async {
                      _engine.resetToDefaults();
                      await EvalDatabaseSettings.instance.resetToDefaults();
                      if (ctx.mounted) Navigator.pop(ctx);
                    },
                    child: const Text('Reset'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

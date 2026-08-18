/// Launch flows for the two interactive repertoire-building modes:
/// build-from-games (draft review) and build-by-playing (guided session).
///
/// Each flow is dialog + controller orchestration: gather the form's initial
/// values from the repertoire state, show the form, then hand the chosen
/// config to the owning controller and bring the Lines/Draft surface into
/// view. Extracted from RepertoireScreen so the flow rules — when "from
/// current position" is offered, where usernames persist, what an active
/// session means for the launch button — are testable without the screen.
/// The form presenters are injectable for exactly that reason.
library;

import 'package:flutter/material.dart';

import '../../../constants/chess_constants.dart';
import '../../../core/app_state.dart';
import '../../../core/generation_session_controller.dart';
import '../../../core/repertoire_controller.dart';
import '../../../services/build_by_playing/build_by_playing_config.dart';
import '../../../services/build_by_playing/build_by_playing_controller.dart';
import '../../../services/games_library/games_library_service.dart';
import '../../../services/games_repertoire/games_draft_controller.dart';
import '../../../widgets/build_by_playing/build_by_playing_form.dart';
import '../../../widgets/games_repertoire/games_source_form.dart';

/// Presents the games-source form; matches [showGamesSourceForm].
typedef GamesSourceFormPresenter =
    Future<GamesSourceConfig?> Function(
      BuildContext context, {
      bool initialIsWhite,
      String? initialChesscomUsername,
      String? initialLichessUsername,
      bool atRoot,
      String? rootFen,
      String? currentFen,
      List<String> currentMoveSans,
    });

/// Presents the build-by-playing form; matches [showBuildByPlayingForm].
typedef BuildByPlayingFormPresenter =
    Future<BuildByPlayingConfig?> Function(
      BuildContext context, {
      required BuildByPlayingConfig initial,
      required bool atRoot,
      String? rootFen,
      List<String> rootMoveSans,
      String? currentFen,
      List<String> currentMoveSans,
      bool boardFlipped,
    });

class BuildLauncher {
  BuildLauncher({
    required this.repertoire,
    required this.draft,
    required this.session,
    required this.generation,
    required this.appState,
    required this.showLinesSurface,
    BuildByPlayingSettings? settings,
    this.gamesForm = showGamesSourceForm,
    this.sessionForm = showBuildByPlayingForm,
  }) : settings = settings ?? BuildByPlayingSettings.instance;

  final RepertoireController repertoire;
  final GamesDraftController draft;
  final BuildByPlayingController session;
  final GenerationSessionController generation;

  /// Supplied per call — the screen resolves it from its context.
  final AppState Function() appState;

  /// Bring the Lines/Draft surface into view (tools tab or side panel).
  final VoidCallback showLinesSurface;

  final BuildByPlayingSettings settings;
  final GamesSourceFormPresenter gamesForm;
  final BuildByPlayingFormPresenter sessionForm;

  Future<void> buildFromGames(BuildContext context) async {
    final app = appState();
    // Real games always start from the initial position, so the from-current
    // option only makes sense for standard-start repertoires.
    final standardStart = repertoire.startingFen == null;
    final config = await gamesForm(
      context,
      initialIsWhite: repertoire.isRepertoireWhite,
      initialChesscomUsername: app.chesscomUsername,
      initialLichessUsername: app.lichessUsername,
      atRoot: !standardStart || repertoire.currentMoveSequence.isEmpty,
      rootFen: kStandardStartFen,
      currentFen: standardStart ? repertoire.fen : null,
      currentMoveSans: standardStart
          ? repertoire.currentMoveSequence
          : const [],
    );
    if (config == null || !context.mounted) return;

    // Remember the username app-wide so tactics / weakness finder reuse it.
    if (config.platform == GamesPlatform.chesscom) {
      app.setChesscomUsername(config.username);
    } else {
      app.setLichessUsername(config.username);
    }

    // Bring the Lines/Draft surface into view and show progress inline.
    showLinesSurface();
    // Diff against the union of every repertoire line — the working tree is
    // only the currently loaded line and would misclassify everything else.
    final error = await draft.build(
      config: config,
      repertoire: repertoire.buildRepertoireMoveTree(),
    );
    if (error != null && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
    }
  }

  Future<void> startBuildByPlaying(BuildContext context) async {
    if (repertoire.currentRepertoire == null) return;
    if (session.isActive) {
      showLinesSurface();
      return;
    }
    final config = await sessionForm(
      context,
      initial: settings.config,
      atRoot: repertoire.isAtRootPosition,
      rootFen: repertoire.rootFen,
      rootMoveSans: repertoire.rootMoveSans,
      currentFen: repertoire.fen,
      currentMoveSans: repertoire.currentMoveSequence,
      boardFlipped: !repertoire.isRepertoireWhite,
    );
    if (config == null || !context.mounted) return;
    await settings.applyFrom(config);
    showLinesSurface();
    await session.start(
      config,
      generatedTree: generation.generatedTree,
      fenMap: generation.generatedTreeFenMap,
    );
  }

  /// Mid-session knob changes from the session pane's gear icon.
  Future<void> openSessionSettings(BuildContext context) async {
    final config = await sessionForm(
      context,
      initial: session.config,
      atRoot: true, // start-from choice is meaningless mid-session
    );
    if (config == null || !context.mounted) return;
    await settings.applyFrom(config);
    session.updateConfig(config);
  }
}

/// A screen-to-screen handoff waiting to be picked up.
///
/// The app's top-level screens live in an `IndexedStack`, so switching modes
/// does not build the target screen — it may already be mounted and will only
/// learn about the switch through an [AppState] notification. Whatever the
/// source screen wanted the target to *do* ("open this line", "seed the
/// generation tab with these PGNs") therefore has to be parked somewhere the
/// target can read when it wakes up.
///
/// This used to be nine loose mutable fields on [AppState]. Nothing tied the
/// related ones together, so producers had to remember to null the fields
/// their route did not use, and consumers had to remember to clear every field
/// they read — a field read but not cleared would silently re-fire on the next
/// unrelated notification.
///
/// One sealed value fixes both ends: a handoff is created complete, and
/// [AppState.takeHandoff] removes it in the same step that reads it, so it can
/// be delivered exactly once.
library;

import 'app_state.dart' show AppMode;

sealed class PendingHandoff {
  const PendingHandoff();

  /// Mode the app switches to in order to deliver this handoff.
  AppMode get targetMode;

  /// Breadcrumb text when the producer passes no explicit label to
  /// [AppState.handOff] — derived from the payload so every crumb is named.
  String get defaultHistoryLabel;
}

/// File name without directory or `.pgn`, for breadcrumb labels.
String _displayName(String path) {
  final base = path.split(RegExp(r'[/\\]')).last;
  return base.toLowerCase().endsWith('.pgn')
      ? base.substring(0, base.length - 4)
      : base;
}

/// Open a repertoire in the Builder.
final class OpenBuilder extends PendingHandoff {
  const OpenBuilder({
    required this.repertoirePath,
    this.lineId,
    this.moveSequence,
    this.generationPgnPaths,
  });

  final String repertoirePath;

  /// Line to focus once the repertoire is loaded.
  final String? lineId;

  /// SAN sequence to navigate the board to after load — the trainer's
  /// "Explore this position".
  final List<String>? moveSequence;

  /// When set, open the generation tab in DB Explorer mode pre-seeded with
  /// these PGN files.
  final List<String>? generationPgnPaths;

  @override
  AppMode get targetMode => AppMode.repertoire;

  @override
  String get defaultHistoryLabel =>
      'Repertoire: ${_displayName(repertoirePath)}';
}

/// Load something into the Repertoire Trainer. Both variants land on the same
/// screen, which cares only about the path, the optional line, and whether to
/// treat the file as a study.
sealed class TrainerHandoff extends PendingHandoff {
  const TrainerHandoff();

  String get sourcePath;
  String? get lineId;

  /// True when the source is a study whose chapters are puzzles, rather than
  /// a repertoire of lines.
  bool get isStudy;

  @override
  AppMode get targetMode => AppMode.repertoireTrainer;

  @override
  String get defaultHistoryLabel => 'Training: ${_displayName(sourcePath)}';
}

/// Train a repertoire's lines.
final class TrainRepertoire extends TrainerHandoff {
  const TrainRepertoire({required this.sourcePath, this.lineId});

  @override
  final String sourcePath;

  @override
  final String? lineId;

  @override
  bool get isStudy => false;
}

/// Train a study's chapters as custom puzzles.
final class TrainStudy extends TrainerHandoff {
  const TrainStudy({required this.sourcePath, this.lineId});

  @override
  final String sourcePath;

  @override
  final String? lineId;

  @override
  bool get isStudy => true;
}

/// Open a study for editing in Study mode.
final class EditStudy extends PendingHandoff {
  const EditStudy({required this.studyPath});

  final String studyPath;

  @override
  AppMode get targetMode => AppMode.study;

  @override
  String get defaultHistoryLabel => 'Study: ${_displayName(studyPath)}';
}

/// Open a PGN collection in the PGN Viewer.
final class OpenPgnViewer extends PendingHandoff {
  const OpenPgnViewer({
    required this.pgnPath,
    this.sliceFen,
    this.gameId,
    this.autoAnalyze = false,
  });

  final String pgnPath;

  /// When set, the viewer slices the collection to games passing through this
  /// position.
  final String? sliceFen;

  /// When set, jump to the game with this identity (a games-library
  /// `dedupKey`: the game URL, else players+date). Indices are not used
  /// because the collection's order can change between refreshes.
  final String? gameId;

  /// Start the engine game review after opening, unless cached evals already
  /// cover the game (the Games page's "Review" button).
  final bool autoAnalyze;

  @override
  AppMode get targetMode => AppMode.pgnViewer;

  @override
  String get defaultHistoryLabel => 'PGN: ${_displayName(pgnPath)}';
}

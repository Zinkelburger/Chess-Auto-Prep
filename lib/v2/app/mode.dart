import '../features/library/chapter_outline.dart';
import '../features/library/library.dart';
import '../features/my_games/game_book.dart';
import '../features/pgn_viewer/auto_play.dart';
import '../features/pgn_viewer/pgn_viewer.dart';
import '../features/study/studies.dart';
import '../features/tactics/my_games.dart';
import '../features/tactics/puzzle_trainer.dart';
import '../features/tactics/tactics_set.dart';
import '../features/trainer/trainer.dart';

/// The modes `v2` has. Each one fills the left column; the workspace, the
/// document and the draft in it are the same whichever is showing.
enum Mode {
  repertoires('Repertoire builder'),
  pgnViewer('PGN Viewer'),
  study('Study'),
  tactics('Tactics'),
  myGames('My games');

  const Mode(this.label);

  final String label;
}

/// The owners behind the lists of the modes that open documents: the
/// repertoires and the open chapter's outline, the studies and the PGN
/// Viewer's files and autoplay. Each disposes with this.
final class DocumentModes {
  const DocumentModes({
    required this.library,
    required this.outline,
    required this.studies,
    required this.viewer,
    required this.autoplay,
  });

  final Library library;
  final ChapterOutline outline;
  final Studies studies;
  final PgnViewer viewer;

  /// The viewer's Space: the game played forward on its own.
  final AutoPlay autoplay;

  void dispose() {
    autoplay.dispose();
    outline.dispose();
    library.dispose();
    studies.dispose();
    viewer.dispose();
  }
}

/// The owners behind the modes that train: the tactics set and its
/// sittings, the repertoire trainer, and the user's own games — mined into
/// puzzles in Tactics, read against the repertoires in My games.
final class TrainingModes {
  const TrainingModes({
    required this.tactics,
    required this.puzzles,
    required this.lines,
    required this.myGames,
    required this.book,
  });

  final TacticsSet tactics;
  final PuzzleTrainer puzzles;

  /// The Train tab's owner: the repertoire's lines and the sitting.
  final Trainer lines;

  /// The usernames and the review that mines their games into the set.
  final MyGames myGames;

  /// The user's games read against their repertoires: My games.
  final GameBook book;

  void dispose() {
    lines.dispose();
    myGames.dispose();
    book.dispose();
    tactics.dispose();
    puzzles.dispose();
  }
}

import 'package:flutter/foundation.dart';

import '../diagnostics/log.dart';
import '../features/bughouse/bughouse_lab.dart';
import '../features/bughouse/lab_engine.dart';
import '../features/library/chapter_outline.dart';
import '../features/library/library.dart';
import '../features/my_games/game_book.dart';
import '../features/pgn_viewer/auto_play.dart';
import '../features/pgn_viewer/pgn_viewer.dart';
import '../features/study/studies.dart';
import '../features/tactics/my_games.dart';
import '../features/tactics/puzzle_trainer.dart';
import '../features/tactics/source_games.dart';
import '../features/tactics/tactics_set.dart';
import '../features/trainer/trainer.dart';
import '../storage/pgn_file_import.dart';
import '../storage/pgn_file_picker.dart';
import '../workspace/file_filter.dart';
import 'trap_training.dart';

/// The app's modes. Each one fills the left column beside the one
/// workspace; the documents each has open are its own, so going to a mode
/// brings back what it had on the board (`DocumentTabs`).
enum Mode {
  repertoires('Repertoire builder'),
  trainer('Repertoire trainer'),
  books('Opening books'),
  pgnViewer('PGN Viewer'),
  study('Study'),
  tactics('Tactics'),
  myGames('My games'),
  playerAnalysis('Player analysis'),
  players('Players & prep'),
  databases('Databases'),
  engineTournament('Engine tournament'),
  bughouse('Bughouse');

  const Mode(this.label);

  final String label;

  /// Whether the mode shows the board and the document tabs; the rest are
  /// a screen of their own, which leave the document where it is.
  bool get showsBoard => !const {
    Mode.books,
    Mode.players,
    Mode.databases,
    Mode.engineTournament,
    Mode.bughouse,
  }.contains(this);

  /// Whether this mode and [other] share their documents: the trainer
  /// drills the builder's repertoires from the same list, so a chapter up in
  /// one is up in the other.
  bool sharesDocumentsWith(Mode other) => _shelf == other._shelf;

  Mode get _shelf => this == Mode.trainer ? Mode.repertoires : this;
}

/// Task groups share their names and membership across navigation surfaces.
const modeGroups = {
  'Repertoires': [Mode.repertoires, Mode.books, Mode.trainer],
  'Study & games': [Mode.pgnViewer, Mode.study, Mode.myGames, Mode.tactics],
  'Opponent preparation': [Mode.playerAnalysis, Mode.players],
  'Data & engines': [Mode.databases, Mode.engineTournament, Mode.bughouse],
};

/// The owners behind the lists of the modes that open documents: the
/// repertoires and the open chapter's outline, the studies, the PGN
/// Viewer's files and autoplay, and the filter over the open file's games.
/// Each disposes with this.
final class DocumentModes {
  const DocumentModes({
    required this.library,
    required this.outline,
    required this.studies,
    required this.viewer,
    required this.filter,
    required this.autoplay,
  });

  final Library library;
  final ChapterOutline outline;
  final Studies studies;
  final PgnViewer viewer;

  /// Which games of the open file pass: the viewer's list and the
  /// explorer's `This file` both read it.
  final FileFilter filter;

  /// The viewer's Space: the game played forward on its own.
  final AutoPlay autoplay;

  void dispose() {
    autoplay.dispose();
    outline.dispose();
    library.dispose();
    studies.dispose();
    viewer.dispose();
    filter.dispose();
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
    required this.sources,
    required this.traps,
  });

  final TacticsSet tactics;
  final PuzzleTrainer puzzles;

  /// The games the puzzles came from: the Game tab's and the list's.
  final SourceGames sources;

  /// The Train tab's owner: the repertoire's lines and the sitting.
  final Trainer lines;

  /// The usernames and the review that mines their games into the set.
  final MyGames myGames;

  /// The user's games read against their repertoires: My games.
  final GameBook book;

  /// A trap's line from the Positions list, trained in the builder.
  final TrapTraining traps;

  void dispose() {
    sources.dispose();
    lines.dispose();
    myGames.dispose();
    book.dispose();
    tactics.dispose();
    puzzles.dispose();
  }
}

/// The owners behind the labs, the modes with a screen of their own: the
/// Bughouse mode's table and what Hivemind makes of it, and the file dialog
/// and reader its moves are opened through. [offered] says whether this
/// build has the engine, which is what puts the mode in the mode menu at all.
final class LabModes {
  LabModes({
    required this.lab,
    required this.engine,
    required this.picker,
    required this.files,
  });

  final BughouseLab lab;
  final LabEngine engine;
  final PgnFilePicker picker;
  final PgnFileImport files;
  final offered = ValueNotifier(false);
  bool _disposed = false;

  /// Asks whether the build carries the engine, and offers the Bughouse
  /// mode if so.
  Future<void> offer(Future<bool> Function() bundled) async {
    try {
      final yes = await bundled();
      if (!_disposed) offered.value = yes;
    } on Object catch (error) {
      log.w('ask whether this build has the bughouse engine', error);
    }
  }

  void dispose() {
    _disposed = true;
    offered.dispose();
    engine.dispose();
    lab.dispose();
  }
}

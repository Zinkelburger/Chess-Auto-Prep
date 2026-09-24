import 'package:flutter/foundation.dart';

import '../diagnostics/log.dart';
import '../features/bughouse/archive_moves.dart';
import '../features/bughouse/bughouse_lab.dart';
import '../features/bughouse/matches.dart';
import '../features/bughouse/table_search.dart';
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
import '../workspace/file_filter.dart';

/// The modes `v2` has. Each one fills the left column; the workspace, the
/// document and the draft in it are the same whichever is showing.
enum Mode {
  repertoires('Repertoire builder'),
  books('Books'),
  pgnViewer('PGN Viewer'),
  study('Study'),
  tactics('Tactics'),
  myGames('My games'),
  bughouse('Bughouse lab');

  const Mode(this.label);

  final String label;
}

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

/// The owners behind the labs, the modes with a screen of their own: the
/// Bughouse lab's table, what Hivemind and its book say about it, and the
/// FICS archive, and the matches. [offered] says whether this build has the engine, which
/// is what puts the lab in the mode menu at all.
final class LabModes {
  LabModes({
    required this.lab,
    required this.search,
    required this.archive,
    required this.matches,
  });

  final BughouseLab lab;
  final TableSearch search;
  final ArchiveMoves archive;

  /// Hivemind against itself from the table on the boards.
  final Matches matches;
  final offered = ValueNotifier(false);
  bool _disposed = false;

  /// Asks whether the build carries the engine, and offers the lab if so.
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
    matches.dispose();
    archive.dispose();
    search.dispose();
    lab.dispose();
  }
}

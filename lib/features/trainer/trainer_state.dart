/// What the trainer is showing and what it takes in: its scope, where a line
/// sent to be read goes, and the states the Train tab draws.
///
/// These are values, so they live apart from the owner that produces them and
/// a widget can be written against them alone.
library;

import '../../chess/training/schedule.dart';
import '../../chess/training/training_line.dart';
import '../../storage/chapter_files.dart';
import '../../storage/training_progress.dart';
import 'progress.dart';
import 'training_scope.dart';

/// How much the trainer takes in: the chapter on the board, every chapter
/// of its repertoire, or every chapter of the book in use.
enum TrainScope { chapter, repertoire, book, studyChapter }

/// Where a line sent to be read goes: the board alone, the tab staying
/// where it is; the Moves tab; or the builder.
enum ReadIn { board, moves, builder }

/// A line sent to be read: its chapter, the moves up to the position to
/// show, and where.
typedef LineToRead = ({
  ChapterRef ref,
  int? game,
  List<String> sans,
  ReadIn place,
});

/// Why there is nothing to train.
enum NothingToTrain { noChapter, studyChapter, noBook, emptyBook }

sealed class TrainerState {
  const TrainerState();
}

/// Nothing has asked for the trainer since the chapter changed.
final class TrainerIdle extends TrainerState {
  const TrainerIdle();
}

final class TrainerEmpty extends TrainerState {
  const TrainerEmpty(this.why);

  final NothingToTrain why;
}

final class TrainerLoading extends TrainerState {
  const TrainerLoading();
}

/// The progress files could not be read; nothing is trained until they can.
final class TrainerFailed extends TrainerState {
  const TrainerFailed(this.failure);

  final ProgressRead failure;
}

final class TrainerReady extends TrainerState {
  const TrainerReady({
    required this.chapters,
    required this.progress,
    this.study = false,
  });

  /// A study stays a file of separate games when a line is opened to read.
  final bool study;

  /// The scope's chapters in the folder's order, each with its lines.
  final List<ChapterLines> chapters;
  final TrainingProgress progress;

  List<TrainingLine> get lines => [
    for (final chapter in chapters) ...chapter.lines,
  ];

  /// The line [key] names, if the scope has it.
  TrainingLine? lineOf(LineKey key) =>
      lines.where((line) => line.key == key).firstOrNull;

  /// [line] as far as [ply] — the whole of it when null — to be read in
  /// [place].
  LineToRead toRead(TrainingLine line, ReadIn place, {int? ply}) => (
    // By the line, not its file: one file can hold several chapters.
    ref: chapters.firstWhere((c) => c.lines.any((l) => l.key == line.key)).ref,
    game: study ? line.game : null,
    sans: [
      for (final move in line.moves.take(ply ?? line.moves.length)) move.san,
    ],
    place: place,
  );
}

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
enum NothingToTrain { noChapter, studyChapter, emptyBook }

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
  TrainerReady({
    required this.chapters,
    required this.progress,
    this.study = false,
  });

  /// A study stays a file of separate games when a line is opened to read.
  final bool study;

  /// The scope's chapters in the folder's order, each with its lines.
  final List<ChapterLines> chapters;
  final TrainingProgress progress;

  late final List<TrainingLine> lines = List.unmodifiable([
    for (final chapter in chapters) ...chapter.lines,
  ]);

  /// Each line by its key, with the chapter holding it; the first wins.
  late final Map<LineKey, (TrainingLine, ChapterRef)> _byKey = () {
    final byKey = <LineKey, (TrainingLine, ChapterRef)>{};
    for (final chapter in chapters) {
      for (final line in chapter.lines) {
        byKey.putIfAbsent(line.key, () => (line, chapter.ref));
      }
    }
    return byKey;
  }();

  /// The line [key] names, if the scope has it.
  TrainingLine? lineOf(LineKey key) => _byKey[key]?.$1;

  /// [line] as far as [ply] — the whole of it when null — to be read in
  /// [place].
  LineToRead toRead(TrainingLine line, ReadIn place, {int? ply}) => (
    // By the line, not its file: one file can hold several chapters.
    ref: _byKey[line.key]!.$2,
    game: study ? line.game : null,
    sans: [
      for (final move in line.moves.take(ply ?? line.moves.length)) move.san,
    ],
    place: place,
  );
}

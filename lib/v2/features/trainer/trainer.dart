import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../chess/pgn/chapter.dart';
import '../../chess/pgn/chapter_sections.dart';
import '../../chess/training/line_order.dart';
import '../../chess/training/schedule.dart';
import '../../chess/training/sitting.dart';
import '../../chess/training/training_line.dart';
import '../../diagnostics/log.dart';
import '../../storage/chapter_files.dart';
import '../../storage/pgn_document_store.dart';
import '../../storage/training_store.dart';
import '../../workspace/board_claim.dart';
import '../../workspace/document_session.dart';
import '../../workspace/engine_analysis.dart';
import 'lesson.dart';
import 'progress.dart';

/// How much of the repertoire the trainer takes in: the chapter on the
/// board, or every chapter of its repertoire.
enum TrainScope { chapter, repertoire }

/// Where a line sent to be read goes: the board alone, the tab staying
/// where it is; the Moves tab; or the builder.
enum ReadIn { board, moves, builder }

/// A line sent to be read: its chapter, the moves up to the position to
/// show, and where.
typedef LineToRead = ({ChapterRef ref, List<String> sans, ReadIn place});

/// Why there is nothing to train.
enum NothingToTrain { noChapter, studyChapter }

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
  const TrainerReady({required this.chapters, required this.progress});

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
    sans: [
      for (final move in line.moves.take(ply ?? line.moves.length)) move.san,
    ],
    place: place,
  );
}

/// How many new lines one Learn sitting takes: enough to learn in one go,
/// few enough to remember tomorrow.
const learnSitting = 10;

/// The Train tab's owner: the lines of the open chapter, or of its whole
/// repertoire, with their progress, and the sitting being trained.
///
/// It follows the document session. A new chapter or scope reads the
/// progress again; an edit to the open chapter only works its lines out
/// again. Nothing is read until the tab asks ([show]), so a window where
/// nobody trains never reads the training files.
///
/// While a sitting runs the trainer holds the board ([board]) and pauses the
/// engine, whose lines would give the answers away.
class Trainer extends ChangeNotifier {
  Trainer({
    required DocumentSession session,
    required ScopeReader chapters,
    required ProgressFiles files,
    required EngineAnalysis analysis,
    required TrainerTime time,
  }) : _session = session,
       _chapters = chapters,
       _files = files,
       _analysis = analysis,
       _time = time {
    _session.addListener(_follow);
  }

  final DocumentSession _session;
  final ScopeReader _chapters;
  final ProgressFiles _files;
  final EngineAnalysis _analysis;
  final TrainerTime _time;
  TrainerState _state = const TrainerIdle();
  TrainScope _scope = TrainScope.chapter;
  LineOrder _order = LineOrder.training;
  Lesson? _lesson;

  /// What was last read: the chapter and scope a load was for, which a
  /// later load or a newer chapter overtakes.
  ({ChapterRef? ref, TrainScope scope, Object? chapter})? _read;

  /// Counts loads, so an older one that finishes late is not taken for the
  /// newest when both asked for the same thing.
  var _loads = 0;

  /// The board while a sitting holds it; null otherwise.
  final board = ValueNotifier<BoardClaim?>(null);

  static const _pauseReason = 'Hidden while training';

  TrainerState get state => _state;

  /// How many lines of the scope a Review sitting takes now, and how many
  /// Learn has left to take.
  int get dueCount => _queue(dueNow).length;
  int get untrainedCount => _queue(toLearn).length;

  List<TrainingLine> _queue(
    List<TrainingLine> Function(
      List<TrainingLine>,
      Map<LineKey, Review>,
      DateTime,
    )
    queue,
  ) {
    final state = _state;
    if (state is! TrainerReady) return const [];
    final progress = state.progress;
    return queue(state.lines, progress.reviews, progress.now);
  }

  TrainScope get scope => _scope;
  Lesson? get lesson => _lesson;

  /// How the tab lists the lines. Kept here, not in the list, so a sitting
  /// comes back to the order it left.
  LineOrder get order => _order;

  set order(LineOrder order) {
    if (order == _order) return;
    _order = order;
    notifyListeners();
  }

  /// Reads what the tab shows, if it has not been read for this chapter.
  void show() {
    if (_state is TrainerIdle) unawaited(_load());
  }

  void setScope(TrainScope scope) {
    if (scope == _scope) return;
    _scope = scope;
    unawaited(_load());
  }

  /// Reads the progress again: after another session changed it, or to
  /// try a file that could not be read.
  Future<void> reload() => _load(force: true);

  /// A sitting of the lines never trained, [learnSitting] at a time.
  void learn() => _sit(SittingKind.learn, (lines, progress) {
    return toLearn(
      lines,
      progress.reviews,
      progress.now,
    ).take(learnSitting).toList();
  });

  /// A sitting of every line due now.
  void review() => _sit(
    SittingKind.review,
    (lines, progress) => dueNow(lines, progress.reviews, progress.now),
  );

  /// A sitting of [line] alone, whatever its status.
  void trainLine(TrainingLine line) =>
      _sit(SittingKind.line, (_, _) => line.modelGame ? const [] : [line]);

  /// Ends the sitting. A line not yet rated is left as it was.
  void leave() {
    final lesson = _lesson;
    if (lesson == null) return;
    lesson
      ..removeListener(_lessonChanged)
      ..dispose();
    _lesson = null;
    board.value = null;
    if (_analysis.pausedFor == _pauseReason) _analysis.resume();
    notifyListeners();
  }

  void _sit(
    SittingKind kind,
    List<TrainingLine> Function(List<TrainingLine>, TrainingProgress) pick,
  ) {
    final state = _state;
    if (state is! TrainerReady || state.progress.stale) return;
    // A line with none of the user's moves in it has nothing to ask.
    final lines = [
      for (final line in pick(state.lines, state.progress))
        if (line.yourMoves > 0) line,
    ];
    if (lines.isEmpty) return;
    leave();
    _lesson = Lesson(kind: kind, lines: lines, progress: state.progress)
      ..addListener(_lessonChanged);
    if (!_analysis.paused) _analysis.pause(_pauseReason);
    _lessonChanged();
  }

  void _lessonChanged() {
    final lesson = _lesson;
    board.value = lesson == null || lesson.state is SittingOver
        ? null
        : lesson.claim;
    notifyListeners();
  }

  /// Keeps up with the session: another chapter reads everything again,
  /// an edit to this one works its lines out again. Another chapter of the
  /// repertoire being trained whole is one already read — a line sent to be
  /// read from the list — so only its lines are worked out again.
  void _follow() {
    final read = _read;
    if (read == null || _session.source != read.ref) {
      if (_inRepertoire(_session.source)) return _relined();
      if (_state is! TrainerIdle) unawaited(_load());
      return;
    }
    if (!identical(_session.chapter, read.chapter)) _relined();
  }

  bool _inRepertoire(ChapterRef? ref) {
    final state = _state;
    return ref != null &&
        _scope == TrainScope.repertoire &&
        _session.chapter?.game == null &&
        state is TrainerReady &&
        state.chapters.any((c) => c.ref == ref);
  }

  /// The open chapter's lines again, after an edit: the progress stays.
  void _relined() {
    final state = _state;
    final chapter = _session.chapter;
    final ref = _session.source;
    if (state is! TrainerReady || chapter == null || ref == null) return;
    _read = (ref: ref, scope: _scope, chapter: chapter);
    final lines = trainingLines(chapter, source: ref.path);
    _state = TrainerReady(
      chapters: [
        for (final c in state.chapters)
          c.ref == ref ? (ref: ref, lines: lines) : c,
      ],
      progress: state.progress,
    );
    notifyListeners();
  }

  Future<void> _load({bool force = false}) async {
    final chapter = _session.chapter;
    final ref = _session.source;
    final wanted = (ref: ref, scope: _scope, chapter: chapter);
    if (!force && _read == wanted && _state is! TrainerIdle) return;
    _read = wanted;
    final load = ++_loads;
    // The sitting was over the progress this replaces; it ends with it, so
    // nothing writes through a copy the files have moved past.
    leave();
    if (chapter == null || ref == null) {
      return _become(const TrainerEmpty(NothingToTrain.noChapter));
    }
    if (chapter.game != null) {
      return _become(const TrainerEmpty(NothingToTrain.studyChapter));
    }
    _become(const TrainerLoading());
    final open = trainingLines(chapter, source: ref.path);
    final chapters = _scope == TrainScope.chapter
        ? [(ref: ref, lines: open)]
        : await _chapters.repertoireOf(ref, open);
    if (load != _loads) return;
    final read = await _files.read({for (final c in chapters) c.ref.path});
    if (load != _loads) return;
    _become(switch (read) {
      ProgressLoaded() => TrainerReady(
        chapters: chapters,
        progress: TrainingProgress(files: _files, loaded: read, time: _time),
      ),
      _ => TrainerFailed(read),
    });
    // An edit made while the files were read is in the lines too.
    _follow();
  }

  void _become(TrainerState state) {
    final was = _state;
    if (was is TrainerReady) was.progress.dispose();
    _state = state;
    notifyListeners();
  }

  @override
  void dispose() {
    _session.removeListener(_follow);
    leave();
    final state = _state;
    if (state is TrainerReady) state.progress.dispose();
    board.dispose();
    super.dispose();
  }
}

/// One chapter's lines, under the chapter they come from.
typedef ChapterLines = ({ChapterRef ref, List<TrainingLine> lines});

/// Reads the other chapters of a repertoire, for training it whole.
final class ScopeReader {
  const ScopeReader({
    required ChapterFiles files,
    required PgnDocumentStore documents,
  }) : _files = files,
       _documents = documents;

  final ChapterFiles _files;
  final PgnDocumentStore _documents;

  /// The chapters of the repertoire [open] is in, in the folder's order,
  /// with [open] itself taken from [openLines] rather than read again: the
  /// board has it, edits and all. A proposed chapter is left out, being
  /// nobody's repertoire yet, and so is one that cannot be read, which is
  /// logged: one bad file does not stop the rest being trained.
  Future<List<ChapterLines>> repertoireOf(
    ChapterRef open,
    List<TrainingLine> openLines,
  ) async {
    final listing = await _files.list();
    final folder = listing is Repertoires
        ? listing.folders
              .where((f) => f.chapters.any((c) => c.path == open.path))
              .firstOrNull
        : null;
    if (folder == null) return [(ref: open, lines: openLines)];
    // A file of several chapters is read once for all of them.
    final files = <String, Future<Chapter?>>{};
    return [
      for (final ref in folder.chapters)
        if (ref == open)
          (ref: open, lines: openLines)
        else if (!ref.heading.draft)
          if (await (files[ref.path] ??= _read(ref)) case final file?)
            (
              ref: ref,
              lines: trainingLines(
                sectionView(file, ref.section).chapter,
                source: ref.path,
              ),
            ),
    ];
  }

  Future<Chapter?> _read(ChapterRef ref) async {
    switch (await _documents.open(ref)) {
      case Opened(:final text):
        return readChapter(name: ref.fileName, text: text);
      case Absent():
        return null;
      case Unreadable(:final detail):
        log.w('read ${ref.path} to train its repertoire', detail);
        return null;
    }
  }
}

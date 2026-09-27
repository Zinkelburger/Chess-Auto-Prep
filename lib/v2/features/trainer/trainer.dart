import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../chess/pgn/chapter.dart';
import '../../chess/training/line_order.dart';
import '../../chess/training/schedule.dart';
import '../../chess/training/sitting.dart';
import '../../chess/training/training_line.dart';
import '../../chess/training/training_options.dart';
import '../../storage/settings_store.dart';
import '../../storage/chapter_files.dart';
import '../../storage/document_ref.dart';
import '../../storage/document_repository.dart';
import '../../storage/training_store.dart';
import '../../storage/pending_writes.dart';
import '../../workspace/board_claim.dart';
import '../../workspace/books.dart';
import '../../workspace/repertoire_catalog.dart';
import '../../workspace/document_session.dart';
import '../../workspace/engine_analysis.dart';
import 'lesson.dart';
import 'progress.dart';
import 'training_scope.dart';

/// How much the trainer takes in: the chapter on the board, every chapter
/// of its repertoire, or every chapter of the book in use.
enum TrainScope { chapter, repertoire, book }

/// Where a line sent to be read goes: the board alone, the tab staying
/// where it is; the Moves tab; or the builder.
enum ReadIn { board, moves, builder }

/// A line sent to be read: its chapter, the moves up to the position to
/// show, and where.
typedef LineToRead = ({ChapterRef ref, List<String> sans, ReadIn place});

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
///
/// Training never stands in the way of the documents it reads: a chapter
/// saved, renamed or deleted under a scope is read again afterwards, and
/// the workspace's own saves of the open chapter only move on the version
/// the progress writes against.
class Trainer extends ChangeNotifier {
  Trainer({
    required DocumentSession session,
    required ScopeReader chapters,
    required ProgressFiles files,
    required EngineAnalysis analysis,
    required TrainerTime time,
    required Books books,
    RepertoireCatalog? catalog,
    PendingWrites? pendingWrites,
    this.settings,
  }) : pendingWrites = pendingWrites ?? PendingWrites(),
       _catalog = catalog,
       _books = books,
       _session = session,
       _chapters = chapters,
       _files = files,
       _analysis = analysis,
       _time = time {
    settings?.addListener(_settingsChanged);
    _session.addListener(_follow);
    _savedRevision = _session.persistedRevision;
    _session.persistedChanges.addListener(_saved);
    _books.addListener(_bookChanged);
    _catalog?.addListener(_catalogChanged);
  }

  final SettingsStore? settings;
  TrainingOptions get options =>
      settings?.value.training ?? TrainingOptions.defaults;
  void _settingsChanged() => notifyListeners();

  int sittingCount(int count, int limit) =>
      limit == 0 || count < limit ? count : limit;
  int get learnCount => sittingCount(untrainedCount, options.learnLimit);
  int get reviewCount => sittingCount(dueCount, options.reviewLimit);

  final RepertoireCatalog? _catalog;
  final PendingWrites pendingWrites;
  final Books _books;

  int _catalogInputs = -1;

  /// A document under the scope was created, saved, moved or deleted, or
  /// the list was read again. The workspace's saves of the open chapter
  /// reach the lines through the session instead ([_follow], [_saved]),
  /// unless the file holds other chapters of the scope too.
  void _catalogChanged() {
    if (_state is TrainerIdle) return;
    final catalog = _catalog!;
    if (_catalogInputs == catalog.inputsRevision) return;
    _catalogInputs = catalog.inputsRevision;
    final change = catalog.admittedChange;
    if (change != null) {
      final source = _session.source;
      final inputs = switch (_scope) {
        TrainScope.book => _books.inputs(_books.active),
        TrainScope.chapter => {if (source != null) source.path},
        TrainScope.repertoire => {
          if (source != null) ?catalog.repertoireOf(source.path),
        },
      };
      if (!inputs.any(change.touches)) return;
      final wholeFile =
          _session.game == null &&
          source?.section == null &&
          catalog.repertoires
                  .expand((folder) => folder.chapters)
                  .where((chapter) => chapter.path == source?.path)
                  .length <=
              1;
      if (wholeFile &&
          change.kind == DocumentChangeKind.saved &&
          change.path == source?.path) {
        return;
      }
    }
    unawaited(_load(force: true));
  }

  /// The book in use as the last load saw it.
  (int, bool)? _bookSeen;

  final DocumentSession _session;
  Revision? _savedRevision;

  /// The workspace wrote the open chapter. Its progress writes against the
  /// new version from now on; a version the progress was not read against
  /// means the file changed some other way, and the scope is read again.
  void _saved() {
    final revision = _session.persistedRevision;
    if (revision == _savedRevision &&
        revision?.nativeIdentity == _savedRevision?.nativeIdentity)
      return;
    _savedRevision = revision;
    final path = _session.source?.path;
    if (_read?.ref?.path != path) return;
    final state = _state;
    final receipt = _session.persistedChange;
    if (path != null &&
        state is TrainerReady &&
        receipt != null &&
        state.progress.documentSaved(
          path,
          receipt.beforeRevision,
          receipt.committed,
        )) {
      _state = TrainerReady(
        chapters: [
          for (final c in state.chapters)
            (
              ref: c.ref,
              lines: c.lines,
              revision: c.ref.path == path ? revision : c.revision,
            ),
        ],
        progress: state.progress,
      );
      notifyListeners();
      return;
    }
    if (_state is! TrainerIdle) unawaited(_load(force: true));
  }

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
  ({ChapterRef? ref, TrainScope scope, Chapter? chapter})? _read;

  /// Counts loads, so an older one that finishes late is not taken for the
  /// newest when both asked for the same thing.
  var _loads = 0;
  bool _disposed = false;

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
  /// try a file that could not be read. A book is read again with it.
  Future<void> reload() async {
    if (_scope == TrainScope.book && !_disposed) {
      await (_books.canRetry ? _books.retry() : _books.load());
    }
    await _load(force: true);
  }

  /// A sitting of the lines never trained, up to the configured limit.
  void learn() => _sit(SittingKind.learn, (lines, progress) {
    return toLearn(
      lines,
      progress.reviews,
      progress.now,
    ).take(learnCount).toList();
  });

  /// A sitting of the lines due now, up to the configured limit.
  void review() => _sit(
    SittingKind.review,
    (lines, progress) => dueNow(
      lines,
      progress.reviews,
      progress.now,
    ).take(reviewCount).toList(),
  );

  /// A retained row action selects its key in the current scope, never the
  /// old moves captured before a reload or document replacement.
  void trainLine(TrainingLine line) =>
      _sit(SittingKind.line, (lines, progress) {
        final current = lines
            .where((candidate) => candidate.key == line.key)
            .firstOrNull;
        return current == null ||
                current.modelGame ||
                progress.status(current) == LineStatus.excluded
            ? const []
            : [current];
      });

  /// Ends the sitting. A line not yet rated is left as it was.
  void leave() {
    final lesson = _lesson;
    if (lesson == null) return;
    lesson
      ..removeListener(_lessonChanged)
      ..dispose();
    _lesson = null;
    board.value = null;
    _analysis.resume(this);
    notifyListeners();
  }

  void _sit(
    SittingKind kind,
    List<TrainingLine> Function(List<TrainingLine>, TrainingProgress) pick,
  ) {
    final state = _state;
    if (_disposed || state is! TrainerReady || state.progress.stale) return;
    // A line with none of the user's moves in it has nothing to ask.
    final lines = [
      for (final line in pick(state.lines, state.progress))
        if (line.yourMoves > 0) line,
    ];
    if (lines.isEmpty) return;
    leave();
    _lesson = Lesson(
      kind: kind,
      lines: lines,
      progress: state.progress,
      options: options,
    )..addListener(_lessonChanged);
    _analysis.pause(this, _pauseReason);
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
  /// read from the list — so only its lines are worked out again. One game
  /// of the file on its own, as the viewer shows it, is another document
  /// even when the file is the same: its side is that game's, and it is not
  /// the chapter to train.
  void _follow() {
    final read = _read;
    final chapter = _session.chapter;
    if (read == null ||
        _session.source != read.ref ||
        chapter?.game != read.chapter?.game) {
      if (_inRepertoire(_session.source)) return _relined();
      // A book is trained whatever is on the board: another chapter that
      // is not in it changes nothing.
      if (_scope == TrainScope.book && _state is TrainerReady) {
        _read = (ref: _session.source, scope: _scope, chapter: chapter);
        return;
      }
      if (_state is! TrainerIdle) unawaited(_load());
      return;
    }
    if (!identical(chapter, read.chapter)) {
      if (_state is TrainerReady) {
        _relined();
      } else if (_state is! TrainerIdle) {
        unawaited(_load(force: true));
      }
    }
  }

  /// Another book is in use, or the one in use was edited: a book being
  /// trained is read again.
  void _bookChanged() {
    final seen = (_books.revision, _books.current);
    if (seen == _bookSeen) return;
    _bookSeen = seen;
    if (_scope == TrainScope.book && _state is! TrainerIdle) {
      unawaited(_load(force: true));
    }
  }

  bool _inRepertoire(ChapterRef? ref) {
    final state = _state;
    return ref != null &&
        _scope != TrainScope.chapter &&
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
          c.ref == ref
              ? (
                  ref: ref,
                  lines: lines,
                  revision: _session.trainingSourceRevision,
                )
              : c,
      ],
      progress: state.progress,
    );
    notifyListeners();
  }

  Future<void> _load({bool force = false}) async {
    if (_disposed) return;
    final chapter = _session.chapter;
    final ref = _session.source;
    final wanted = (ref: ref, scope: _scope, chapter: chapter);
    if (!force && _read == wanted && _state is! TrainerIdle) return;
    _read = wanted;
    final load = ++_loads;
    // The sitting was over the progress this replaces; it ends with it, so
    // nothing writes through a copy the files have moved past.
    final previous = _state;
    leave();
    _become(const TrainerLoading());
    if (previous is TrainerReady) await previous.progress.settle();
    if (load != _loads) return;
    if (_scope == TrainScope.book) return _loadBook(load, chapter, ref);
    if (chapter == null || ref == null) {
      return _become(const TrainerEmpty(NothingToTrain.noChapter));
    }
    if (chapter.game != null) {
      return _become(const TrainerEmpty(NothingToTrain.studyChapter));
    }
    final open = (
      ref: ref,
      lines: trainingLines(chapter, source: ref.path),
      revision: _session.trainingSourceRevision,
    );
    final chapters = _scope == TrainScope.chapter
        ? [open]
        : await _chapters.repertoireOf(open);
    if (load != _loads) return;
    await _loaded(load, chapters);
  }

  /// The chapters of the book in use, the one on the board as it stands
  /// when it is one of them.
  Future<void> _loadBook(int load, Chapter? chapter, ChapterRef? ref) async {
    final book = _books.active;
    _bookSeen = (_books.revision, _books.current);
    if (book == null) {
      return _become(const TrainerEmpty(NothingToTrain.noBook));
    }
    final open = chapter != null && ref != null && chapter.game == null
        ? (
            ref: ref,
            lines: trainingLines(chapter, source: ref.path),
            revision: _session.trainingSourceRevision,
          )
        : null;
    final chapters = await _chapters.chaptersWhere(
      (ref) => _books.contains(book, ref),
      open,
    );
    if (load != _loads) return;
    if (chapters.isEmpty) {
      return _become(const TrainerEmpty(NothingToTrain.emptyBook));
    }
    await _loaded(load, chapters);
  }

  /// The progress of [chapters], read for the load counted as [load].
  Future<void> _loaded(int load, List<ChapterLines> chapters) async {
    final read = await _files.read({for (final c in chapters) c.ref.path});
    if (load != _loads) return;
    _become(switch (read) {
      ProgressLoaded() => TrainerReady(
        chapters: chapters,
        progress: TrainingProgress(
          files: _files,
          loaded: read,
          time: _time,
          pendingWrites: pendingWrites,
        ),
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
    _disposed = true;
    // A load still reading is overtaken: it makes no progress to leak and
    // tells nobody.
    _loads++;
    settings?.removeListener(_settingsChanged);
    _session.removeListener(_follow);
    _session.persistedChanges.removeListener(_saved);
    _books.removeListener(_bookChanged);
    _catalog?.removeListener(_catalogChanged);
    leave();
    final state = _state;
    if (state is TrainerReady) state.progress.dispose();
    board.dispose();
    super.dispose();
  }
}

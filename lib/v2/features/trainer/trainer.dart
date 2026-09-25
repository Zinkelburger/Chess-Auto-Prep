import 'dart:async';
import 'dart:math' show Random;

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
import '../../workspace/document_saver.dart' show DocumentWriteGuard;
import '../../workspace/engine_analysis.dart';
import 'lesson.dart';
import 'progress.dart';
import 'training_scope.dart';
import '../../storage/book_snapshot.dart';

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

/// Accepted progress belongs to the app even when its former scope is gone.
/// Do not publish a fresh scope over unresolved writes to the same files.
final class TrainerUnsaved extends TrainerState {
  const TrainerUnsaved(this.failure);

  final ProgressWrite failure;
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
class Trainer extends ChangeNotifier implements DocumentWriteGuard {
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

  @override
  Future<String?> pauseForWrite() async {
    if (_documentWrites++ == 0) {
      _pausedProgress = switch (_state) {
        TrainerReady(:final progress) => progress,
        _ => null,
      };
      _pausedLesson = _lesson;
      _pausedProgress?.suspend();
      _pausedLesson?.suspend();
      if (_state is TrainerLoading) {
        _loads++;
        _reloadAfterWrite = true;
      }
      if (!_disposed) _lessonChanged();
    }
    await pendingWrites.settleFor(_files);
    return pendingWrites.unfinished(_files).firstOrNull?.detail;
  }

  @override
  void resumeAfterWrite() {
    if (_documentWrites == 0 || --_documentWrites != 0) return;
    _pausedProgress?.resume();
    _pausedLesson?.resume();
    _pausedProgress = null;
    _pausedLesson = null;
    if (_disposed) return;
    if (_reloadAfterWrite) {
      _reloadAfterWrite = false;
      unawaited(_load(force: true));
    } else {
      _lessonChanged();
    }
  }

  int _documentWrites = 0;
  bool _reloadAfterWrite = false;
  TrainingProgress? _pausedProgress;
  Lesson? _pausedLesson;
  bool get documentWriting => _documentWrites != 0;
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

  void _catalogChanged() {
    if (_state is TrainerIdle) return;
    final catalog = _catalog!;
    // A batch can contain an open-chapter save AND a sibling rename. Ignore
    // only batches made entirely of saves the session already supplies.
    final source = _session.source;
    final wholeFile =
        _session.game == null &&
        source?.section == null &&
        catalog.repertoires
                .expand((folder) => folder.chapters)
                .where((chapter) => chapter.path == source?.path)
                .length <=
            1;
    // A course save may have changed another section of this same file.
    if (wholeFile &&
        !catalog.reloaded &&
        catalog.changes.every(
          (change) =>
              change.kind == DocumentChangeKind.saved &&
              change.path == _session.source?.path,
        ))
      return;
    unawaited(_load(force: true));
  }

  /// The book in use as the last load saw it.
  (int, bool)? _bookSeen;

  final DocumentSession _session;
  Revision? _savedRevision;

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
  bool _relocating = false;
  bool _reloadAfterRelocation = false;
  bool _disposed = false;

  /// Stops every old-path producer before the caller takes storage locks.
  /// Disposed scopes' accepted attempts and ratings share this same resource.
  /// A failed obligation refuses relocation until its exact retry succeeds.
  Future<String?> retireForRelocation() async {
    if (_relocating) return 'Training is already waiting for a document move.';
    _relocating = true;
    _reloadAfterRelocation = _state is! TrainerIdle;
    _loads++;
    if (!_disposed) {
      leave();
      if (_reloadAfterRelocation) _become(const TrainerLoading());
    }
    await pendingWrites.settleFor(_files);
    return pendingWrites.unfinished(_files).firstOrNull?.detail;
  }

  /// The caller has finished publishing and synchronizing its catalog.
  Future<void> resumeAfterRelocation() async {
    if (!_relocating) return;
    _relocating = false;
    if (!_disposed && _reloadAfterRelocation) await _load(force: true);
  }

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
  Future<void> reload() {
    if (_scope != TrainScope.book ||
        _disposed ||
        _relocating ||
        documentWriting) {
      return _load(force: true);
    }
    return _bookReload ??= _refreshBook().whenComplete(
      () => _bookReload = null,
    );
  }

  Future<void>? _bookReload;
  bool _refreshingBook = false;

  Future<void> _refreshBook() async {
    _refreshingBook = true;
    _loads++;
    leave();
    _become(const TrainerLoading());
    try {
      if (_books.canRetry) {
        await _books.retry();
      } else {
        await _books.load();
      }
    } finally {
      _refreshingBook = false;
    }
    // Book notifications invalidate the old load but do not recursively start
    // another read while this explicit refresh owns the replacement.
    await _load(force: true);
  }

  /// Replays the original accepted mutations, including their store tokens;
  /// only after they land may a replacement scope read their result.
  Future<void> retryPending() async {
    if (_disposed || _relocating || documentWriting) return;
    final load = ++_loads;
    leave();
    _become(const TrainerLoading());
    await pendingWrites.retry(_files);
    if (load != _loads) return;
    await _load(force: true);
  }

  /// Also visible after leaving a failed lesson without changing scope.
  ProgressWrite? get unsavedProgress {
    final result = pendingWrites.unfinished(_files).firstOrNull?.result;
    return result is ProgressWrite ? result : null;
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

  /// Quiz a chosen set immediately, including lines not due yet. Each line
  /// occurs once; ratings still update its schedule and mistakes are logged.
  void drillLines(List<TrainingLine> wanted) =>
      _sit(SittingKind.drill, (lines, progress) {
        final keys = wanted.map((line) => line.key).toSet();
        final picked = [
          for (final line in ordered(
            lines,
            order,
            reviews: progress.reviews,
            now: progress.now,
          ))
            if (keys.contains(line.key) &&
                line.yourMoves > 0 &&
                !line.modelGame &&
                progress.status(line) != LineStatus.excluded)
              line,
        ];
        if (options.shuffleDrill) picked.shuffle(Random());
        return picked
            .take(sittingCount(picked.length, options.drillLimit))
            .toList();
      });

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
    if (_disposed ||
        _relocating ||
        documentWriting ||
        state is! TrainerReady ||
        state.progress.stale)
      return;
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
    if (_refreshingBook) return;
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
    if (_disposed || _refreshingBook) return;
    if (documentWriting) {
      _reloadAfterWrite = true;
      return;
    }
    if (_relocating) {
      _reloadAfterRelocation = true;
      return;
    }
    final chapter = _session.chapter;
    final ref = _session.source;
    final revision = _session.trainingSourceRevision;
    final wanted = (ref: ref, scope: _scope, chapter: chapter);
    if (!force && _read == wanted && _state is! TrainerIdle) return;
    _read = wanted;
    final load = ++_loads;
    // The sitting was over the progress this replaces; it ends with it, so
    // nothing writes through a copy the files have moved past.
    leave();
    _become(const TrainerLoading());
    await pendingWrites.settleFor(_files);
    if (load != _loads) return;
    final unsaved = pendingWrites.unfinished(_files).firstOrNull;
    if (unsaved != null) {
      return _become(
        TrainerUnsaved(
          unsaved.result is ProgressWrite
              ? unsaved.result as ProgressWrite
              : ProgressFailed(unsaved.detail),
        ),
      );
    }
    if (_scope == TrainScope.book) return _loadBook(load, chapter, ref);
    if (chapter == null || ref == null) {
      return _become(const TrainerEmpty(NothingToTrain.noChapter));
    }
    if (chapter.game != null) {
      return _become(const TrainerEmpty(NothingToTrain.studyChapter));
    }
    _become(const TrainerLoading());
    final open = (
      ref: ref,
      lines: trainingLines(chapter, source: ref.path),
      revision: revision,
    );
    final captured = _scope == TrainScope.chapter
        ? TrainingScopeReady([open])
        : await _chapters.repertoireOf(open);
    if (load != _loads) return;
    await _loaded(load, captured, sourceRevision: revision);
  }

  /// Freeze the acknowledged book before reading any of its chapters.
  Future<void> _loadBook(int load, Chapter? chapter, ChapterRef? ref) async {
    final book = _books.active;
    final bookRevision = _books.revision;
    final source = _books.source;
    final revision = _session.trainingSourceRevision;
    _bookSeen = (bookRevision, _books.current);
    if (!_books.current) {
      return _become(
        const TrainerFailed(
          ProgressFailed(
            'Book membership is not saved or could not be read. Retry after saving it.',
          ),
        ),
      );
    }
    if (book == null) {
      return _loaded(
        load,
        TrainingScopeReady(const []),
        sourceRevision: revision,
        bookRevision: bookRevision,
        bookSource: source,
        empty: NothingToTrain.noBook,
      );
    }
    final open = chapter != null && ref != null && chapter.game == null
        ? (
            ref: ref,
            lines: trainingLines(chapter, source: ref.path),
            revision: revision,
          )
        : null;
    final captured = await _chapters.chaptersWhere(
      (ref) => _books.contains(book, ref),
      open,
    );
    if (load != _loads) return;
    await _loaded(
      load,
      captured,
      sourceRevision: revision,
      bookRevision: bookRevision,
      bookSource: source,
    );
  }

  /// The last await is one storage fence over membership, PGNs, books and
  /// progress. Synchronous owner checks then decide whether to publish.
  Future<void> _loaded(
    int load,
    TrainingScopeRead captured, {
    required Revision? sourceRevision,
    int? bookRevision,
    BookSource? bookSource,
    NothingToTrain empty = NothingToTrain.emptyBook,
  }) async {
    if (captured is TrainingScopeFailed) {
      return _become(TrainerFailed(ProgressFailed(captured.detail)));
    }
    final scope = captured as TrainingScopeReady;
    final read = await _files.read(
      scope.observed.keys.toSet(),
      observed: scope.observed,
    );
    if (load != _loads) return;
    if (read is! ProgressLoaded) return _become(TrainerFailed(read));
    final checked = await _chapters.validate(
      scope,
      book: bookSource,
      training: read.snapshot,
    );
    if (load != _loads || _disposed || _relocating || documentWriting) return;
    final refusal = _scopeRefusal(sourceRevision, bookRevision, checked);
    if (refusal != null) return _become(refusal);
    if (bookRevision != null && scope.chapters.isEmpty) {
      return _become(TrainerEmpty(empty));
    }
    _become(
      TrainerReady(
        chapters: scope.chapters,
        progress: TrainingProgress(
          files: _files,
          loaded: read,
          time: _time,
          pendingWrites: pendingWrites,
        ),
      ),
    );
  }

  TrainerState? _scopeRefusal(
    Revision? sourceRevision,
    int? bookRevision,
    RepertoireValidation checked,
  ) {
    if (_session.source != _read?.ref ||
        !identical(_session.chapter, _read?.chapter) ||
        _session.trainingSourceRevision != sourceRevision ||
        _session.trainingSourceRevision?.nativeIdentity !=
            sourceRevision?.nativeIdentity ||
        (bookRevision != null &&
            (!_books.current || _books.revision != bookRevision))) {
      return const TrainerFailed(
        ProgressFailed(
          'Training inputs changed while loading. Reload to retry.',
        ),
      );
    }
    final unsaved = pendingWrites.unfinished(_files).firstOrNull;
    if (unsaved != null) return TrainerUnsaved(ProgressFailed(unsaved.detail));
    return switch (checked) {
      RepertoireCurrent() => null,
      RepertoireValidationFailed(:final detail) => TrainerFailed(
        ProgressFailed(detail),
      ),
      RepertoireChanged() => const TrainerFailed(
        ProgressFailed(
          'Training inputs changed while loading. Reload to retry.',
        ),
      ),
    };
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

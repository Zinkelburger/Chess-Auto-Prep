/// Reading and writing training progress: the review schedule, the move
/// streaks, the rating history and the log of answers, in the Documents
/// folder the old app keeps them in.
///
/// Both apps write these files, so a write is optimistic. It says what each
/// row it changes held when it was read (`before`) and what it holds now
/// (`after`); under the Documents lock — the one the old app takes for the
/// same files — a row that holds neither was changed by somebody else, and
/// the whole write is refused rather than put over their answer. Only the
/// rows a write names are touched; every other record keeps its bytes.
///
/// Every file is read and checked before any is written. The first write to
/// a file keeps a `<file>.pre-csv-v2.bak` copy of it, as the old app does.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:path/path.dart' as p;

import '../chess/training/records.dart';
import '../chess/training/schedule.dart';
import '../diagnostics/log.dart';
import 'atomic_write.dart';
import 'csv_records.dart';
import 'document_probe.dart';
import 'document_ref.dart';
import 'file_lock.dart';
import 'file_relocation.dart';
import 'training_records.dart' show repointedBytes;
import 'recovery_gate.dart';
import 'recovery_files.dart';
import 'training_rows.dart';
import 'training_snapshot.dart';
import 'operation_id.dart';
import 'training_payload.dart';
import 'training_writes.dart';

/// A change accepted by [TrainingStore] and not yet written.
final class _Accepted {
  _Accepted(this.operation, this.payload, {required this.projectedBeforeMove})
    : sources = operation.sources,
      moveMark = FileRelocations.moveMark;
  final ProgressOperation operation;

  /// The change and the PGNs it names, where its chapters are now.
  String payload;
  Map<String, Revision> sources;

  /// Chapter moves already followed: every move made before this one was
  /// accepted, and those since that [TrainingStore._follow] applied.
  int moveMark;

  /// Source authority is checked when the command enters the queue. Once
  /// accepted, its answer survives later saves; a transient read failure
  /// keeps the command waiting until that original authority can be checked.
  Future<ProgressWrite?>? admission;
  bool verified = false;

  /// A chapter it names moved between its read and its acceptance, so its
  /// rows were projected from a path that names something else now.
  final bool projectedBeforeMove;

  /// The bytes an earlier attempt set out to publish, per file.
  final attempted = <String, List<int>>{};

  /// The chapters its rows name, where they are now.
  Set<String> get chapters => TrainingPayload.decode(payload).sources;
}

/// The changes one pass over the queue holds back, and why: the chapters
/// they name, as their rows spell them, and their operations.
final class _Held {
  final _chapters = <String, String>{};
  final _operations = <String, String>{};

  /// Why [change] must wait, or null when nothing it depends on waits.
  String? waitingFor(_Accepted change) {
    if (_operations.isEmpty) return null;
    for (final path in change.chapters) {
      if (_chapters[path] case final why?) return why;
    }
    return _operations[change.operation.predecessorId];
  }

  void add(_Accepted change, String why) {
    for (final path in change.chapters) {
      _chapters.putIfAbsent(path, () => why);
    }
    _operations[change.operation.id] = why;
  }
}

/// A row as read and as it is to be written; `before` is null for a row the
/// file did not have.
typedef Change<T> = ({T? before, T after});

/// Where one move's streak lives: its line and its ply.
typedef StreakKey = ({LineKey line, int ply});

/// Stable identity and source proofs captured before a change is accepted.
/// Retrying with the same operation never writes the change twice.
final class ProgressOperation {
  ProgressOperation({
    String? id,
    this.predecessorId,
    Map<String, Revision> sources = const {},
  }) : id = id ?? newOperationId(),
       sources = Map.unmodifiable(sources),
       _moveMark = FileRelocations.moveMark;

  /// Chapter moves made before the sources were read; a later move of one
  /// of them means its path names something else now.
  final int _moveMark;

  final String id;

  /// An earlier accepted command this projected row baseline depends on.
  final String? predecessorId;

  /// The PGNs that supplied this command, captured before it was queued.
  final Map<String, Revision> sources;

  (String, String)? _identity;

  /// How this change was written, once it has been, or refused for good.
  ProgressWrite? _settled;
}

/// The training files. The filesystem is a real boundary, so this is an
/// interface: [TrainingStore] in the app, a scripted one in tests.
abstract interface class ProgressFiles {
  /// Accepts frozen changes without waiting for earlier ones to be written.
  /// A retry must reuse this same operation.
  Future<ProgressAdmission> enqueueWrite({
    List<Change<Review>> reviews = const [],
    List<Change<MoveStreak>> streaks = const [],
    List<HistoryRow> history = const [],
    required ProgressOperation operation,
  });
  Future<ProgressAdmission> enqueueAttempt(
    Attempt attempt, {
    required ProgressOperation operation,
  });

  /// Writes the accepted changes up to and including this one, each once.
  Future<ProgressWrite> commit(ProgressOperation operation);

  /// Everything recorded for these sources. When PGN input was already read,
  /// [observed] binds the rows to those exact persisted observations. Without
  /// it this read captures a fresh source observation for a storage caller.
  Future<ProgressRead> read(
    Set<String> sources, {
    Map<String, Revision>? observed,
  });

  /// Writes a line's outcome, or a change to the schedule by hand: the
  /// [reviews] and [streaks] rows it changes and the [history] it adds.
  /// Retain [operation] to retry this exact command after a failed outcome;
  /// omitting it accepts a new operation, even when its rows are identical.
  Future<ProgressWrite> write({
    List<Change<Review>> reviews,
    List<Change<MoveStreak>> streaks,
    List<HistoryRow> history,
    ProgressOperation? operation,
  });

  /// Adds one answer to the log, as it is given. Reuse [operation] only
  /// for a retry of this answer; distinct answers need distinct tokens.
  Future<ProgressWrite> logAttempt(
    Attempt attempt, {
    ProgressOperation? operation,
  });
}

final class TrainingStore implements ProgressFiles {
  TrainingStore(
    this.documents, {
    required Directory support,
    Future<void> Function(String, List<int>) publish = replaceFile,
    Future<void> Function(TrainingWriteStep)? trainingHook,
    RecoveryGate? recovery,
    this._lock = withDirectoryLock,
  }) : _writer = TrainingWriter(
         documents: canonicalRecoveryRoot(documents),
         publish: publish,
         testHook: trainingHook,
       ),
       _recovery =
           recovery ?? RecoveryGate(documents: documents, support: support);

  /// The profile's gate, shared with its document store so an edit a failed
  /// save left half done is finished before an answer is written over it.
  final RecoveryGate _recovery;

  final TrainingWriter _writer;
  final Future<ProgressWrite> Function(
    Directory,
    Future<ProgressWrite> Function(),
  )
  _lock;

  /// Changes accepted and not yet written, oldest first. A later commit
  /// writes the earlier ones first, so each chapter's rows land in the order
  /// they were projected.
  final _queued = <String, _Accepted>{};

  /// The folder the four files sit in, beside `repertoires/`.
  final Directory documents;

  /// Decoded mistakes are reusable only for the exact bytes just observed.
  ({String hash, List<Attempt> wrong})? _log;

  /// The unreadable rows already logged, by file and line.
  final _passedOver = <(String, int)>{};

  @override
  Future<ProgressRead> read(
    Set<String> sources, {
    Map<String, Revision>? observed,
  }) async {
    final wanted = Set<String>.of(sources);
    final baseline = observed == null
        ? null
        : Map<String, Revision>.of(observed);
    try {
      return await _recovery.run(
        () => withDirectoryLock(documents, () async {
          await _drainForRead();
          final versions = await _sources(wanted, baseline);
          return _read(wanted, versions);
        }),
      );
    } on _Changed catch (error) {
      return ProgressFailed(
        'The training source changed: ${error.row}. Reload it.',
      );
    } on RecoveryRequired catch (error) {
      return ProgressFailed(error.detail);
    } on _Unreadable catch (unreadable) {
      return unreadable.result;
    } on FileSystemException catch (error) {
      log.e('read the training progress in ${documents.path}', error);
      return ProgressFailed(_detail(error));
    }
  }

  Future<ProgressLoaded> _read(
    Set<String> sources,
    Map<String, Revision> versions,
  ) async {
    final participants = <String, Revision?>{};
    final observed = {
      for (final name in trainingParticipants)
        name: await _observed(name, participants),
    };
    // The revisions stay the disk's, so a change made elsewhere is still
    // noticed; the rows include what this store accepted and has not written.
    final files = _overlaid(observed);
    final reviews = _rows(_reviewCodec, files[reviewsFile]);
    final streaks = _rows(_streakCodec, files[streaksFile]);
    final attempts = files[attemptsFile];
    final wrong = _wrongAnswers(
      attempts,
      identical(attempts, observed[attemptsFile])
          ? participants[attemptsFile]?.contentHash
          : null,
    );
    // A key written twice is read as its first row, the one a write
    // replaces.
    final byLine = <LineKey, Review>{};
    for (final r in reviews) {
      if (sources.contains(r.key.source)) {
        byLine.putIfAbsent(r.key, () => r);
      }
    }
    final byMove = <StreakKey, MoveStreak>{};
    for (final s in streaks) {
      if (!sources.contains(s.key.source)) continue;
      byMove.putIfAbsent((line: s.key, ply: s.ply), () => s);
    }
    return ProgressLoaded(
      sources: Map.unmodifiable(versions),
      reviews: Map.unmodifiable(byLine),
      streaks: Map.unmodifiable(byMove),
      mistakes: List.unmodifiable(
        wrong.where((a) => sources.contains(a.key.source)),
      ),
      snapshot: TrainingReadSet(
        documentsPath: p.normalize(documents.absolute.path),
        canonicalDocuments: _writer.documents.path,
        files: participants,
      ),
    );
  }

  @override
  Future<ProgressAdmission> enqueueWrite({
    List<Change<Review>> reviews = const [],
    List<Change<MoveStreak>> streaks = const [],
    List<HistoryRow> history = const [],
    required ProgressOperation operation,
  }) {
    final payload = jsonEncode([
      'write',
      [
        for (final change in reviews)
          [
            change.before == null ? null : _reviewCodec.row(change.before!),
            _reviewCodec.row(change.after),
          ],
      ],
      [
        for (final change in streaks)
          [
            change.before == null ? null : _streakCodec.row(change.before!),
            _streakCodec.row(change.after),
          ],
      ],
      [for (final row in history) encodeHistory(row)],
    ]);
    return _enqueue(payload, operation);
  }

  @override
  Future<ProgressAdmission> enqueueAttempt(
    Attempt attempt, {
    required ProgressOperation operation,
  }) => _enqueue(jsonEncode(['attempt', encodeAttempt(attempt)]), operation);

  Future<ProgressAdmission> _enqueue(
    String payload,
    ProgressOperation operation,
  ) async {
    final String destination;
    try {
      destination = _destination();
    } on Object catch (error) {
      return ProgressRejected(ProgressFailed(_detail(error)));
    }
    final identity = (destination, payload);
    if (operation._identity != null && operation._identity != identity) {
      return const ProgressRejected(ProgressConflict());
    }
    operation._identity = identity;
    final Set<String> paths;
    try {
      paths = TrainingPayload.decode(payload).sources;
      if (paths.any((path) => !operation.sources.containsKey(path))) {
        return const ProgressRejected(ProgressConflict());
      }
    } on FormatException catch (error) {
      return ProgressRejected(ProgressFailed(error.message));
    }
    if (operation._settled == null) {
      final change = _queued.putIfAbsent(
        operation.id,
        () => _Accepted(
          operation,
          payload,
          projectedBeforeMove: paths.any(
            (path) => FileRelocations.movedAwaySince(
              operation._moveMark,
              _writer.canonicalSource(path, _trainingRoot),
            ),
          ),
        ),
      );
      await (change.admission ??= _admission(change));
    }
    return const ProgressEnqueued();
  }

  /// A new answer must name the PGN that supplied its moves, not merely a
  /// path that still exists. This is admission, before subsequent saves or
  /// relocations are allowed to carry an already accepted answer along.
  Future<ProgressWrite?> _admission(_Accepted change) async {
    for (final path in change.chapters) {
      final expected = change.sources[path];
      final canonical = _writer.canonicalSource(path, _trainingRoot);
      switch (await probeDocument(canonical)) {
        case FileFound(:final revision, :final identity):
          if (expected == null ||
              expected != revision ||
              expected.nativeIdentity != identity) {
            return const ProgressConflict();
          }
        case FileMissing() || FileNotPlain():
          return const ProgressConflict();
        case FileNotReadNow(:final detail):
          return ProgressFailed('Training source $path: $detail');
      }
    }
    change.verified = true;
    return null;
  }

  @override
  Future<ProgressWrite> commit(ProgressOperation operation) async {
    final identity = operation._identity;
    if (identity == null) {
      return const ProgressFailed(
        'Enqueue this training command before applying it.',
      );
    }
    if (operation._settled case final settled?) return settled;
    if (!_queued.containsKey(operation.id)) {
      return const ProgressFailed('This training change was not accepted.');
    }
    final result = await _locked('save training progress', () async {
      // A commit that waited for the lock may find its change settled by
      // the one ahead of it.
      if (operation._settled case final settled?) return settled;
      if (_destination() != identity.$1) {
        throw const TrainingChanged('Operation destination');
      }
      // The changes land oldest first. One whose chapter cannot be read
      // right now waits with only the changes that depend on it
      // ([_applyUnlessHeld]); any other failure stays queued with every one
      // after it.
      final held = _Held();
      for (final change in _queued.values.toList()) {
        final outcome = await _applyUnlessHeld(change, held);
        if (change.operation.id == operation.id) return outcome;
      }
      return operation._settled ?? const ProgressWritten();
    });
    _log = null;
    return result;
  }

  /// A read first writes what this store accepted, so a reload never shows
  /// progress older than an accepted change. One that still fails is laid
  /// over the rows the read returns instead ([_overlaid]).
  Future<void> _drainForRead() async {
    if (_queued.isEmpty) return;
    _log = null;
    try {
      final destination = _destination();
      final held = _Held();
      for (final change in _queued.values.toList()) {
        // Left for its commit, which refuses it.
        if (change.operation._identity?.$1 != destination) return;
        await _applyUnlessHeld(change, held);
      }
    } on Object catch (error) {
      log.w('write the queued training progress in ${documents.path}', error);
    }
  }

  /// [files] with the changes still queued laid over them, oldest first. One
  /// that cannot land on them is left out; its commit refuses it. A file an
  /// earlier attempt already published keeps its bytes, as the writer does.
  Map<String, Uint8List?> _overlaid(Map<String, Uint8List?> files) {
    const equal = ListEquality<int>();
    var result = files;
    for (final change in _queued.values) {
      if (change.projectedBeforeMove) continue;
      try {
        _follow(change);
        final before = result;
        result = {...TrainingPayload.decode(change.payload).plan(before)};
        for (final MapEntry(key: name, value: bytes)
            in change.attempted.entries) {
          if (equal.equals(before[name], bytes)) result[name] = before[name];
        }
      } on TrainingChanged {
        continue;
      } on TrainingUnreadable {
        continue;
      }
    }
    return result;
  }

  /// [_apply], unless [change] names a chapter [held] back earlier in this
  /// pass or builds on a change that was. A change whose chapter cannot be
  /// read right now is held back with every chapter it names and stays
  /// queued, to land once it can be read. Every other change still lands,
  /// while each chapter's changes keep their order and none lands before the
  /// one it builds on, so a change that waited never turns into a conflict.
  Future<ProgressWrite> _applyUnlessHeld(_Accepted change, _Held held) async {
    if (!change.projectedBeforeMove) _follow(change);
    if (!change.verified) {
      final admission = await (change.admission ??= _admission(change));
      if (admission is ProgressConflict) return _settle(change, admission);
      if (admission is ProgressFailed) {
        change.admission = null;
        held.add(change, admission.detail);
        return admission;
      }
    }
    if (held.waitingFor(change) case final why?) {
      held.add(change, why);
      return ProgressFailed(why);
    }
    try {
      return await _apply(change);
    } on TrainingSourceNotReadNow catch (error) {
      final why = '${error.message}: ${error.path}';
      log.w('save training progress in ${documents.path}', why);
      held.add(change, why);
      return ProgressFailed(why);
    }
  }

  /// Writes one accepted change. A change that can never be written — its
  /// source or a row it replaces changed, or a row it replaces is unreadable
  /// — leaves the queue with that answer, so the changes after it still
  /// land. One refused by a file that is not rows at all stays queued, to
  /// land once the file is repaired, and does not hold back the changes
  /// after it: those that need the same file are refused by it too.
  Future<ProgressWrite> _apply(_Accepted change) async {
    try {
      if (change.projectedBeforeMove) {
        throw const TrainingChanged('Training source moved before acceptance');
      }
      _follow(change);
      await _writer.apply(
        change.payload,
        change.sources,
        trainingRoot: _trainingRoot,
        attempted: change.attempted,
      );
    } on TrainingChanged catch (error) {
      log.w('save training progress in ${documents.path}', error.detail);
      return _settle(change, const ProgressConflict());
    } on TrainingUnreadable catch (unreadable) {
      final result = ProgressUnreadable(
        unreadable.file,
        unreadable.line,
        wholeFile: unreadable.wholeFile,
      );
      return unreadable.wholeFile ? result : _settle(change, result);
    }
    return _settle(change, const ProgressWritten());
  }

  /// Points [change] at where its chapters went in the moves made since it
  /// was accepted. A rename, a folder move or a delete (into the recovery
  /// folder) repoints the rows already on disk; the change follows them, so
  /// an accepted answer is never dropped for a move made while it waited.
  void _follow(_Accepted change) {
    final since = change.moveMark;
    final now = FileRelocations.moveMark;
    if (since == now) return;
    final root = _trainingRoot;
    final canonical = _writer.documents.path;
    String spelled(String path) =>
        p.join(root, p.relative(path, from: canonical));
    final moved = <String, String>{};
    for (final path in change.sources.keys) {
      final to = FileRelocations.relocatedSince(
        since,
        _writer.canonicalSource(path, root),
      );
      if (to == null) continue;
      // Rows keep the spelling they were written with, as a move keeps both.
      moved[path] = p.isWithin(canonical, path) ? to : spelled(to);
    }
    if (moved.isNotEmpty) {
      change
        ..payload = TrainingPayload.decode(change.payload).relocated(moved)
        ..sources = {
          for (final MapEntry(:key, :value) in change.sources.entries)
            moved[key] ?? key: value,
        };
    }
    change.moveMark = now;
    // A file an earlier attempt published was repointed by every move since,
    // whichever chapter it took, so what that attempt wrote is looked for as
    // the moves left it; a history row or an answer is never appended twice.
    final moves = [
      for (final (from, to) in FileRelocations.movesSince(since)) ...[
        (from, to),
        if (root != canonical) (spelled(from), spelled(to)),
      ],
    ];
    for (final name in change.attempted.keys.toList()) {
      try {
        for (final (from, to) in moves) {
          change.attempted[name] = repointedBytes(
            name,
            change.attempted[name]!,
            from,
            to,
          );
        }
      } on Object catch (error) {
        // Keep the last bytes a move repointed: the relocation that failed
        // here would have refused the same bytes on disk.
        log.w('follow a chapter move in the attempted $name', error);
      }
    }
  }

  ProgressWrite _settle(_Accepted change, ProgressWrite result) {
    _queued.remove(change.operation.id);
    change.operation._settled = result;
    return result;
  }

  @override
  Future<ProgressWrite> write({
    List<Change<Review>> reviews = const [],
    List<Change<MoveStreak>> streaks = const [],
    List<HistoryRow> history = const [],
    ProgressOperation? operation,
  }) async {
    final token = operation ?? ProgressOperation();
    final admission = await enqueueWrite(
      reviews: reviews,
      streaks: streaks,
      history: history,
      operation: token,
    );
    return admission is ProgressRejected ? admission.result : commit(token);
  }

  @override
  Future<ProgressWrite> logAttempt(
    Attempt attempt, {
    ProgressOperation? operation,
  }) async {
    final token = operation ?? ProgressOperation();
    final admission = await enqueueAttempt(attempt, operation: token);
    return admission is ProgressRejected ? admission.result : commit(token);
  }

  Future<Map<String, Revision>> _sources(
    Set<String> paths,
    Map<String, Revision>? expected,
  ) async {
    final versions = <String, Revision>{};
    for (final path in paths) {
      final observed = await probeDocument(path);
      if (observed is! FileFound) throw _Changed('training source $path');
      final before = expected?[path];
      if (expected != null &&
          (before == null ||
              before.nativeIdentity == null ||
              before.nativeIdentity != observed.identity ||
              before != observed.revision)) {
        throw _Changed('training source $path');
      }
      versions[path] = observed.revision;
    }
    return versions;
  }

  Future<ProgressWrite> _locked(
    String action,
    Future<ProgressWrite> Function() write,
  ) async {
    try {
      return await _recovery.run(() => _lock(documents, write));
    } on TrainingUnreadable catch (unreadable) {
      return ProgressUnreadable(
        unreadable.file,
        unreadable.line,
        wholeFile: unreadable.wholeFile,
      );
    } on TrainingChanged {
      return const ProgressConflict();
    } on _Unreadable catch (unreadable) {
      return unreadable.result;
    } on _Changed catch (changed) {
      log.w('$action in ${documents.path}', 'row changed: ${changed.row}');
      return const ProgressConflict();
    } on Object catch (error) {
      log.e('$action in ${documents.path}', error);
      return ProgressFailed(_detail(error));
    }
  }

  String _destination() => p.normalize(
    documents.existsSync()
        ? documents.resolveSymbolicLinksSync()
        : p.absolute(documents.path),
  );

  String _path(String name) => p.join(documents.path, name);

  /// The Documents folder as the app spells it, which rows may name.
  String get _trainingRoot => p.normalize(p.absolute(documents.path));

  /// Records a participant's proof and returns only the bytes it proves.
  Future<Uint8List?> _observed(
    String name,
    Map<String, Revision?> versions,
  ) async {
    switch (await probeDocument(p.join(_writer.documents.path, name))) {
      case FileFound(:final bytes, :final revision):
        versions[name] = revision;
        return bytes;
      case FileMissing():
        versions[name] = null;
        return null;
      case FileUnreadable(:final detail):
        throw FileSystemException(detail, _path(name));
    }
  }

  String? _decodeText(String name, Uint8List? bytes) {
    if (bytes == null) return null;
    try {
      return utf8.decode(bytes);
    } on FormatException catch (error) {
      throw _Unreadable(name, _lineAt(bytes, error.offset));
    }
  }

  /// A row that is not one is passed over, logged once; a write naming its
  /// line refuses it ([TrainingPayload]). Bytes that are not text, or a
  /// quote nobody closed, leave no rows to tell apart: the file is unreadable.
  List<T> _rows<T, K>(_Codec<T, K> codec, Uint8List? bytes) {
    final name = codec.file;
    final text = _decodeText(name, bytes);
    final records = text == null || text.trim().isEmpty
        ? const <CsvRecord>[]
        : switch (readCsvRecords(text)) {
            CsvParsed(:final records) => records,
            CsvUnreadable(:final line) => throw _Unreadable(name, line),
          };
    final header = headerWidth(records);
    final rows = <T>[];
    for (final record in records) {
      final cells = codec.cells(record, header);
      if (cells == null) continue;
      final row = codec.decode(cells);
      if (row != null) {
        rows.add(row);
      } else if (_passedOver.add((name, record.line))) {
        log.w('pass over unreadable $name line ${record.line}');
      }
    }
    return rows;
  }

  /// Preserve the legacy log's tolerance of individual torn/malformed lines.
  /// Only bytes as observed, named by their [hash], are cached.
  List<Attempt> _wrongAnswers(Uint8List? bytes, String? hash) {
    if (bytes == null) return const [];
    final cached = _log;
    if (hash != null && cached?.hash == hash) return cached!.wrong;
    final text = utf8.decode(bytes, allowMalformed: true);
    final wrong = List<Attempt>.unmodifiable([
      for (final line in const LineSplitter().convert(text))
        if (decodeAttempt(line) case final a? when !a.correct) a,
    ]);
    if (hash != null) _log = (hash: hash, wrong: wrong);
    return wrong;
  }
}

/// How the rows of one CSV are read, told apart and written.
final class _Codec<T, K> {
  const _Codec(this.file, this.decode, this.encode, this.key);

  final String file;
  final T? Function(List<String>) decode;
  final List<String> Function(T) encode;
  final K Function(T) key;

  String row(T value) => encodeCsvRecord(encode(value));

  /// The cells of a data row, or null for the header and blank lines. The
  /// width rule is the one a chapter move reads the file with too.
  List<String>? cells(CsvRecord record, int? header) =>
      dataCells(record, record.isBlank ? null : rowWidth(file, record, header));
}

const _reviewCodec = _Codec<Review, LineKey>(
  reviewsFile,
  decodeReview,
  encodeReview,
  _reviewKey,
);

const _streakCodec = _Codec<MoveStreak, StreakKey>(
  streaksFile,
  decodeStreak,
  encodeStreak,
  _streakKey,
);

LineKey _reviewKey(Review review) => review.key;

StreakKey _streakKey(MoveStreak streak) => (line: streak.key, ply: streak.ply);

final class _Unreadable implements Exception {
  _Unreadable(this.file, this.line);

  final String file;
  final int line;

  ProgressUnreadable get result =>
      ProgressUnreadable(file, line, wholeFile: true);
}

final class _Changed implements Exception {
  const _Changed(this.row);

  final String row;
}

sealed class ProgressRead {
  const ProgressRead();
}

final class ProgressLoaded extends ProgressRead {
  const ProgressLoaded({
    required this.reviews,
    required this.streaks,
    required this.mistakes,
    this.sources = const {},
    this.snapshot,
  });

  final TrainingReadSet? snapshot;
  final Map<String, Revision> sources;
  final Map<LineKey, Review> reviews;
  final Map<StreakKey, MoveStreak> streaks;

  /// Wrong answers, oldest first.
  final List<Attempt> mistakes;
}

sealed class ProgressWrite {
  const ProgressWrite();
}

final class ProgressWritten extends ProgressWrite {
  const ProgressWritten();
}

/// The source document changed identity/version, or another session changed
/// a row this write would have replaced. Nothing new is published.
final class ProgressConflict extends ProgressWrite {
  const ProgressConflict();
}

/// A file holds something that is not its rows; nothing was written to any.
final class ProgressUnreadable implements ProgressRead, ProgressWrite {
  const ProgressUnreadable(this.file, this.line, {this.wholeFile = false});

  final String file;
  final int line;

  /// Whether the file holds no rows at all. A write refused by such a file
  /// stays queued, to land once it is repaired; one refused by a single
  /// unreadable row it replaces is settled for good.
  final bool wholeFile;
}

final class ProgressFailed implements ProgressRead, ProgressWrite {
  const ProgressFailed(this.detail);

  /// For the log; the widget writes the sentence.
  final String detail;
}

String _detail(Object error) => error is FileSystemException
    ? error.osError?.message ?? error.message
    : '$error';

const _lineFeed = 0x0A;

/// The line, counting from one, that holds the byte at [offset].
int _lineAt(Uint8List bytes, int? offset) {
  final end = offset == null ? 0 : offset.clamp(0, bytes.length);
  var line = 1;
  for (var i = 0; i < end; i++) {
    if (bytes[i] == _lineFeed) line++;
  }
  return line;
}

sealed class ProgressAdmission {
  const ProgressAdmission();
}

final class ProgressEnqueued extends ProgressAdmission {
  const ProgressEnqueued();
}

final class ProgressRejected extends ProgressAdmission {
  const ProgressRejected(this.result);
  final ProgressWrite result;
}

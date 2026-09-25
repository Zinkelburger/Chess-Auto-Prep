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

import 'package:path/path.dart' as p;

import '../chess/training/records.dart';
import '../chess/training/schedule.dart';
import '../diagnostics/log.dart';
import 'atomic_write.dart';
import 'csv_records.dart';
import 'document_probe.dart';
import 'document_ref.dart';
import 'file_lock.dart';
import 'recovery_gate.dart';
import 'recovery_files.dart';
import 'relocation_notes.dart';
import 'training_rows.dart';
import 'training_snapshot.dart';
import 'reference_change.dart';
import 'training_payload.dart';
import 'training_writes.dart';

/// A change accepted by [TrainingStore] and not yet written.
final class _Accepted {
  _Accepted(this.operation, this.payload);
  final ProgressOperation operation;
  final String payload;

  /// The bytes an earlier attempt set out to publish, per file.
  final attempted = <String, List<int>>{};
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
  }) : id = id ?? newCompoundId(),
       sources = Map.unmodifiable(sources);

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
    this._lock = withDirectoryLock,
  }) : _writer = TrainingWriter(
         documents: canonicalRecoveryRoot(documents),
         publish: publish,
         testHook: trainingHook,
       ),
       _recovery = RecoveryGate(documents: documents, support: support);

  final RecoveryGate _recovery;

  final TrainingWriter _writer;
  final Future<ProgressWrite> Function(
    Directory,
    Future<ProgressWrite> Function(),
  )
  _lock;

  /// Changes accepted and not yet written, oldest first. A later commit
  /// writes the earlier ones first, so rows land in the order they were
  /// projected.
  final _queued = <String, _Accepted>{};

  /// The folder the four files sit in, beside `repertoires/`.
  final Directory documents;

  /// Decoded mistakes are reusable only for the exact bytes just observed.
  ({String hash, List<Attempt> wrong})? _log;

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
    final reviews = _rows(
      _reviewCodec,
      await _observed(reviewsFile, participants),
    );
    final streaks = _rows(
      _streakCodec,
      await _observed(streaksFile, participants),
    );
    await _observed(historyFile, participants);
    final attempts = await _observed(attemptsFile, participants);
    final wrong = _wrongAnswers(attempts, participants[attemptsFile]);
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
    try {
      final paths = TrainingPayload.decode(payload).sources;
      if (paths.any((path) => !operation.sources.containsKey(path))) {
        return const ProgressRejected(ProgressConflict());
      }
    } on FormatException catch (error) {
      return ProgressRejected(ProgressFailed(error.message));
    }
    if (operation._settled == null) {
      _queued.putIfAbsent(operation.id, () => _Accepted(operation, payload));
    }
    return const ProgressEnqueued();
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
      if (_destination() != identity.$1) {
        throw const TrainingChanged('Operation destination');
      }
      for (final change in _queued.values.toList()) {
        final outcome = await _apply(change);
        if (change.operation.id == operation.id) return outcome;
      }
      return const ProgressWritten();
    });
    _log = null;
    return result;
  }

  /// Writes one accepted change. A change that can never be written — its
  /// source or a row it replaces changed — leaves the queue with that
  /// answer, so the changes after it still land.
  Future<ProgressWrite> _apply(_Accepted change) async {
    try {
      await _writer.apply(
        change.payload,
        change.operation.sources,
        trainingRoot: p.normalize(p.absolute(documents.path)),
        attempted: change.attempted,
      );
    } on TrainingChanged catch (error) {
      log.w('save training progress in ${documents.path}', error.detail);
      return _settle(change, const ProgressConflict());
    } on TrainingUnreadable catch (unreadable) {
      return _settle(
        change,
        ProgressUnreadable(unreadable.file, unreadable.line),
      );
    }
    return _settle(change, const ProgressWritten());
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
      return ProgressUnreadable(unreadable.file, unreadable.line);
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

  /// A malformed CSV row invalidates its whole required participant.
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
    return [
      for (final record in records)
        if (codec.cells(record, header) case final cells?)
          codec.decode(cells) ?? (throw _Unreadable(name, record.line)),
    ];
  }

  /// Preserve the legacy log's tolerance of individual torn/malformed lines.
  List<Attempt> _wrongAnswers(Uint8List? bytes, Revision? revision) {
    if (bytes == null || revision == null) return const [];
    final cached = _log;
    if (cached?.hash == revision.contentHash) return cached!.wrong;
    final text = utf8.decode(bytes, allowMalformed: true);
    final wrong = List<Attempt>.unmodifiable([
      for (final line in const LineSplitter().convert(text))
        if (decodeAttempt(line) case final a? when !a.correct) a,
    ]);
    _log = (hash: revision.contentHash, wrong: wrong);
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

  ProgressUnreadable get result => ProgressUnreadable(file, line);
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
  const ProgressUnreadable(this.file, this.line);

  final String file;
  final int line;
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

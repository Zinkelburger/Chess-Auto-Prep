/// The training schedule's half of a chapter rename, move or delete.
///
/// Reviews, move progress and history live in three CSVs in the Documents
/// folder, beside the log of answered moves, a JSON object per line. Every
/// record names its chapter by path — the first CSV column, `repertoire_id`,
/// and the log's `repertoireId`. Move the chapter and say nothing, and the
/// user's scheduling, streaks, history and answers belong to nothing.
///
/// So the store repoints them in the same operation. A row is matched the way
/// the old app matches it, because both apps write these files: the chapter's
/// own path, or any path inside a folder that moved. A third spelling of the
/// same file — a different absolute prefix, left behind by a Documents folder
/// that moved as a whole — is left alone here too; the old app never rewrote
/// those either, and guessing which prefix is stale would be a way to lose
/// somebody's schedule.
///
/// Deleting is a move as well. The store quarantines a chapter rather than
/// unlinking it, so its rows follow it into the recovery folder and come back
/// with it. Nothing about a deleted chapter is thrown away.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:document_file_io/document_file_io.dart';

import '../diagnostics/log.dart';
import 'atomic_write.dart';
import 'csv_records.dart';
import 'document_ref.dart';
import 'operation_id.dart';
import 'operation_journal.dart';
import 'training_rows.dart';
import 'recovery_files.dart';

/// The training records under one Documents folder.
final class TrainingRecords {
  const TrainingRecords(this.documents);

  /// The folder the four files sit in, beside `repertoires/`.
  final Directory documents;

  /// Capture all four participants without writing. The caller holds the
  /// Documents lock through planning and any later publication. Malformed
  /// records throw [Malformed]; failed native observations or decoding throw
  /// [IoFailure]. No participant or backup is modified on either failure.
  Future<TrainingRepointPlan> plan(
    DocumentRef from,
    DocumentRef to, {
    DocumentRef? alternateFrom,
    DocumentRef? alternateTo,
  }) async {
    final before = <String, String?>{};
    for (final name in trainingParticipants) {
      before[name] = await _read(name, from.path);
    }
    return TrainingRepointPlan.fromSnapshots(
      from: from,
      to: to,
      before: before,
      alternateFrom: alternateFrom,
      alternateTo: alternateTo,
    );
  }

  /// Rewrites every record that named [from] so it names [to] instead.
  ///
  /// The caller holds the lock on [documents]: this is the second half of a
  /// relocation, and the two halves run under one set of locks so no other
  /// writer sees the chapter moved and its rows not. There is no lock taken
  /// here, so calling this while holding that lock is what it is for.
  ///
  /// Every file is read and checked before any of them is written, so a
  /// malformed record in the last one leaves the others as they were, and
  /// what each one held is kept ([_keepReplaced]) before any of them is
  /// replaced. The files are replaced one atomic publication each; a reader
  /// between two of them sees whole files, never half a row.
  Future<RepointResult> repoint(DocumentRef from, DocumentRef to) async {
    final TrainingRepointPlan planned;
    try {
      planned = await plan(from, to);
    } on Malformed catch (failure) {
      return failure;
    } on IoFailure catch (failure) {
      return failure;
    }
    final changed = planned.files.where((file) => file.changed).toList();
    if (changed.isEmpty) return const NothingToRepoint();
    return _commit(changed, planned.rowsChanged);
  }

  Future<String?> _read(String name, String from) async {
    final path = p.join(documents.path, name);
    final String text;
    final String prefix;
    try {
      final observed = await observeFile(path);
      if (observed.status == 1) {
        return null;
      }
      final bytes = observed.bytes;
      if (observed.status != 0 || bytes == null) {
        throw FileSystemException(
          'Cannot observe training participant $name',
          path,
          OSError('Native observation', observed.error),
        );
      }
      // Dart's UTF-8 decoder consumes a leading BOM. Retain that exact prefix
      // separately while the existing record codecs read the decoded body.
      text = utf8.decode(bytes);
      prefix = hasByteOrderMark(bytes) ? '\ufeff' : '';
    } on FileSystemException catch (error) {
      log.e('read $name to repoint $from', error);
      throw IoFailure(_detail(error));
    } on FormatException catch (error) {
      log.e('read $name to repoint $from', error);
      throw const IoFailure(_notText);
    }
    return '$prefix$text';
  }

  Future<RepointResult> _commit(
    List<TrainingRepointFile> planned,
    int rows,
  ) async {
    final operation = newOperationId();
    try {
      await removeStaleTemporaries(documents);
      for (final file in planned) {
        await _keepReplaced(file, operation);
      }
      for (final file in planned) {
        await replaceFile(
          p.join(documents.path, file.name),
          utf8.encode(file.after!),
        );
      }
    } on Object catch (error) {
      log.e('write the training records under ${documents.path}', error);
      return IoFailure(_detail(error));
    }
    return Repointed(rows);
  }

  /// Keeps the bytes this rewrite is about to replace where the old app keeps
  /// them: `.cap-reference-history/<operation>/<file>` under Documents, one
  /// folder per relocation. A schedule is a year of the user's reviews, and
  /// the four files are the only copy of it, so nothing replaces one of them
  /// until what it held is somewhere else.
  Future<void> _keepReplaced(TrainingRepointFile file, String operation) async {
    final kept = p.join(documents.path, _replacedFolder, operation, file.name);
    await Directory(p.dirname(kept)).create(recursive: true);
    await createFileExclusively(kept, utf8.encode(file.before!));
  }
}

/// A complete immutable read set for one training reference relocation.
final class TrainingRepointPlan {
  TrainingRepointPlan._(List<TrainingRepointFile> files, this.rowsChanged)
    : files = List.unmodifiable(files);

  /// Reconstructs the deterministic transformation from a journal's complete
  /// captured read set. No paths are read and no caller-owned collection is
  /// retained. Missing or extra participant names are an invalid envelope.
  /// A trusted configured root alias can supply a second path spelling; both
  /// mappings are applied before publishing one final snapshot per file.
  factory TrainingRepointPlan.fromSnapshots({
    required DocumentRef from,
    required DocumentRef to,
    required Map<String, String?> before,
    DocumentRef? alternateFrom,
    DocumentRef? alternateTo,
  }) {
    if ((alternateFrom == null) != (alternateTo == null)) {
      throw ArgumentError(
        'Alternate source and destination must be supplied together.',
      );
    }
    if (before.length != trainingParticipants.length ||
        !trainingParticipants.every(before.containsKey)) {
      throw const FormatException(
        'Expected exactly four training participants.',
      );
    }
    final files = <TrainingRepointFile>[];
    var rows = 0;
    for (final name in trainingParticipants) {
      final planned = _planSnapshot(name, before[name], from.path, to.path);
      final alternate = alternateFrom == null
          ? null
          : _planSnapshot(
              name,
              planned.file.after,
              alternateFrom.path,
              alternateTo!.path,
            );
      files.add(
        TrainingRepointFile._(
          name,
          planned.file.before,
          alternate == null ? planned.file.after : alternate.file.after,
        ),
      );
      rows += planned.rowsChanged + (alternate?.rowsChanged ?? 0);
    }
    return TrainingRepointPlan._(files, rows);
  }

  final List<TrainingRepointFile> files;
  final int rowsChanged;
}

/// Exact text before and after relocation. Null means an absent file, distinct
/// from an existing empty file. Unchanged participants remain in the read set.
final class TrainingRepointFile {
  const TrainingRepointFile._(this.name, this.before, this.after);

  final String name;
  final String? before;
  final String? after;
  bool get changed => before != after;
}

/// A move's training rows, which follow its file or folder: as planned while
/// a file holds what the plan read or wrote, planned again from what it
/// holds now when somebody trained in between. A file whose records naming
/// the move cannot be read, or that is not UTF-8 at all, keeps its bytes
/// and is named in [NotFollowed]; the other files still follow.
final class TrainingRows implements Reference {
  TrainingRows.moved(
    this.documents, {
    required this.plan,
    required this.from,
    required this.to,
    required this.trainingRoot,
    this.written,
    this.synchronize = syncDirectory,
  });

  /// The canonical Documents folder the four files sit in.
  final Directory documents;
  final TrainingRepointPlan plan;
  final String from;
  final String to;

  /// The Documents spelling the move was planned under, whose paths the
  /// rows may also name.
  final String trainingRoot;

  /// Told after each file is written, by its name.
  final Future<void> Function(String name)? written;
  final Future<void> Function(String) synchronize;

  // What [look] last read of each file.
  final _looked = <String, String?>{};

  String _path(String name) => p.join(documents.path, name);

  @override
  Future<Holds> look() async {
    String? changed;
    Holds? unreadable;
    for (final file in plan.files) {
      final path = _path(file.name);
      final String? text;
      try {
        text = await recoveryText(path);
      } on RecoveryRequired {
        rethrow;
      } on FileSystemException catch (error) {
        return CannotTell('$error');
      } on Object catch (error) {
        // Read on, so [follow] knows which of the others were here.
        unreadable ??= HoldsOther(describeFailure(error));
        continue;
      }
      _looked[file.name] = text;
      if (text != file.before) changed ??= path;
    }
    if (unreadable != null) return unreadable;
    if (changed == null) return const HoldsBefore();
    return HoldsOther('$changed changed while the move was prepared.');
  }

  @override
  Future<void> follow() async {
    final notFollowed = <String>[];
    for (final file in plan.files) {
      if (await _follow(file) case final detail?) {
        notFollowed.add(detail);
      } else {
        await written?.call(file.name);
      }
    }
    if (notFollowed.isNotEmpty) throw NotFollowed(notFollowed.join(' '));
  }

  /// Why [file] was left as it is, if it was.
  Future<String?> _follow(TrainingRepointFile file) async {
    final path = _path(file.name);
    final String? text;
    try {
      text = await recoveryText(path);
    } on FormatException {
      return '$path is not UTF-8 text.';
    }
    if (text == null && _looked[file.name] != null) {
      // Here a moment ago: it is gone only for now.
      throw FileSystemException('The training file is missing for now', path);
    }
    final String? after;
    if (text == file.before || text == file.after) {
      after = file.after;
    } else {
      try {
        after = _planAgain(file.name, text);
      } on Malformed catch (error) {
        return '$path may name $from at line ${error.line} and cannot be read.';
      }
    }
    await publishExactText(
      path,
      current: text,
      after: after,
      synchronize: synchronize,
    );
    return null;
  }

  /// [text], the training file [name] as it holds now, with the rows naming
  /// [from] under either Documents spelling moved, as
  /// [TrainingRepointPlan.fromSnapshots] plans them. Throws [Malformed].
  String? _planAgain(String name, String? text) {
    String under(String path) =>
        p.join(trainingRoot, p.relative(path, from: documents.path));
    final planned = _planSnapshot(name, text, from, to).file.after;
    return _planSnapshot(name, planned, under(from), under(to)).file.after;
  }
}

sealed class RepointResult {
  const RepointResult();
}

/// [rowsChanged] rows across the four files now name the new path.
final class Repointed extends RepointResult {
  const Repointed(this.rowsChanged);

  final int rowsChanged;
}

/// No row named the old path, so no file was written.
final class NothingToRepoint extends RepointResult {
  const NothingToRepoint();
}

/// A record in [file] at [line] is not the shape the schema describes, and
/// may name the path being moved; or the file's rows cannot be told apart.
///
/// Nothing was written. A training file is a user's whole review history, and
/// a record nobody can read is not one to replace with defaults. One that
/// names nothing being moved keeps its bytes and does not stop the move.
final class Malformed extends RepointResult implements Exception {
  const Malformed(this.file, this.line);

  /// The file's name, such as `repertoire_reviews.csv`.
  final String file;

  /// Counting from one, as an editor numbers lines.
  final int line;
}

/// A read or write failed. Planning failures never change any participant;
/// a commit failure may follow an earlier publication, retained in backups.
final class IoFailure extends RepointResult implements Exception {
  const IoFailure(this.detail);

  /// For the log; the widget writes the sentence.
  final String detail;
}

/// The log of answered moves: one JSON object per line, only ever appended.
const _attempts = attemptsFile;

/// Where the old app keeps what a relocation replaced, under Documents, one
/// folder per operation. Both apps read it, so the name and the shape stay
/// as they are.
const _replacedFolder = '.cap-reference-history';

/// What the attempt log calls the same thing.
const _attemptIdKey = 'repertoireId';

const _notText = 'the file is not UTF-8 text';

({TrainingRepointFile file, int rowsChanged}) _planSnapshot(
  String name,
  String? before,
  String from,
  String to,
) {
  if (before == null) {
    return (file: TrainingRepointFile._(name, null, null), rowsChanged: 0);
  }
  final prefix = before.startsWith('\ufeff') ? '\ufeff' : '';
  final text = before.substring(prefix.length);
  final parsed = text.trim().isEmpty
      ? const _Keep()
      : name == _attempts
      ? _planAttempts(text, from, to)
      : _planText(text, name, from, to);
  return switch (parsed) {
    _Keep() => (
      file: TrainingRepointFile._(name, before, before),
      rowsChanged: 0,
    ),
    _Refused(:final result) => throw result,
    _Rewrite(:final text, :final rowsChanged) => (
      file: TrainingRepointFile._(name, before, '$prefix$text'),
      rowsChanged: rowsChanged,
    ),
  };
}

/// The bytes of training file [name] with every record that named [from]
/// naming [to], as a relocation rewrites that file. Throws [Malformed] when a
/// record that may name [from] cannot be read.
List<int> repointedBytes(
  String name,
  List<int> bytes,
  String from,
  String to,
) => utf8.encode(_planSnapshot(name, exactText(bytes), from, to).file.after!);

/// What one file needs, decided without touching the disk.
sealed class _Plan {
  const _Plan();
}

final class _Keep extends _Plan {
  const _Keep();
}

final class _Rewrite extends _Plan {
  const _Rewrite({required this.text, required this.rowsChanged});

  final String text;
  final int rowsChanged;
}

final class _Refused extends _Plan {
  const _Refused(this.result);

  final Malformed result;
}

_Plan _planText(String text, String name, String from, String to) {
  switch (readCsvRecords(text)) {
    case CsvUnreadable(:final line):
      return _Refused(Malformed(name, line));
    case CsvParsed(:final records):
      return _planRecords(records, name, text, from, to);
  }
}

/// The attempt log, whose records are lines rather than CSV.
///
/// Splitting on the line feed and joining on it again reproduces the file
/// exactly, trailing newline and all, so every answer the user gave that did
/// not name this chapter keeps the bytes it was written with. So does a line
/// this code cannot read, torn or foreign, unless it may name the chapter.
_Plan _planAttempts(String text, String from, String to) {
  final lines = text.split('\n');
  var rows = 0;
  for (var i = 0; i < lines.length; i++) {
    final rewritten = movedAttempt(lines[i], from, to);
    if (rewritten == null) {
      if (mayName(lines[i], from)) return _Refused(Malformed(_attempts, i + 1));
      log.w('keep unreadable $_attempts line ${i + 1} while repointing');
      continue;
    }
    if (rewritten != lines[i]) rows++;
    lines[i] = rewritten;
  }
  if (rows == 0) return const _Keep();
  return _Rewrite(text: lines.join('\n'), rowsChanged: rows);
}

/// One logged answer pointing at its chapter, or null when the line is not
/// a JSON object naming one — which is a line this code will not rewrite.
String? movedAttempt(String line, String from, String to) {
  if (line.trim().isEmpty) return line;
  final Object? decoded;
  try {
    decoded = jsonDecode(line);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, Object?>) return null;
  final id = decoded[_attemptIdKey];
  if (id is! String) return null;
  final moved = movedPath(id, from, to);
  if (moved == null) return line;
  // Spreading first keeps every other field, and its place in the object.
  return jsonEncode({...decoded, _attemptIdKey: moved});
}

_Plan _planRecords(
  List<CsvRecord> records,
  String name,
  String text,
  String from,
  String to,
) {
  final width = headerWidth(records);
  // Without the header there is no way to tell a pre-v2 record whose path
  // held commas from a record with the wrong number of fields.
  if (width == null) return _Refused(Malformed(name, 1));
  final out = StringBuffer();
  var rows = 0;
  for (final record in records) {
    final cells = record.isBlank
        ? null
        : dataCells(record, rowWidth(name, record, width));
    final whole = cells != null && isWholeRow(name, cells, width);
    if (cells != null && !whole) {
      if (mayName(record.source, from)) {
        return _Refused(Malformed(name, record.line));
      }
      log.w('keep unreadable $name line ${record.line} while repointing');
    }
    final text = cells == null || !whole
        ? record.source
        : _rewritten(record, cells, name, width, from, to);
    if (text == null) return _Refused(Malformed(name, record.line));
    if (text != record.source) rows++;
    out
      ..write(text)
      ..write(record.terminator);
  }
  if (rows == 0) return const _Keep();
  return _Rewrite(text: out.toString(), rowsChanged: rows);
}

/// The record with its chapter moved, or null when the row written would
/// not read back as the row meant — a row corrupted, so the move is refused
/// before any file is replaced.
String? _rewritten(
  CsvRecord record,
  List<String> cells,
  String name,
  int width,
  String from,
  String to,
) {
  final moved = movedPath(cells.first, from, to);
  if (moved == null) return record.source;
  final meant = [moved, ...cells.skip(1)];
  final text = encodeCsvRecord(meant);
  if (readCsvRecords(text) case CsvParsed(records: [final written])) {
    final read = dataCells(written, rowWidth(name, written, width));
    if (read != null &&
        read.length == meant.length &&
        Iterable<int>.generate(read.length).every((i) => read[i] == meant[i])) {
      return text;
    }
  }
  return null;
}

/// Where [path] is once [from] moved to [to], or null when that move did not
/// take it. The old app's matching rule, which this one must agree with
/// exactly.
String? movedPath(String path, String from, String to) {
  if (p.equals(from, to)) return null;
  if (p.equals(path, from)) return to;
  if (p.isWithin(from, path)) return p.join(to, p.relative(path, from: from));
  return null;
}

String _detail(Object error) => error is FileSystemException
    ? error.osError?.message ?? error.message
    : '$error';

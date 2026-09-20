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
import 'dart:math';

import 'package:path/path.dart' as p;

import '../diagnostics/log.dart';
import 'atomic_write.dart';
import 'csv_records.dart';
import 'document_ref.dart';

/// The training records under one Documents folder.
final class TrainingRecords {
  const TrainingRecords(this.documents);

  /// The folder the three files sit in, beside `repertoires/`.
  final Directory documents;

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
    if (p.equals(from.path, to.path)) return const NothingToRepoint();
    return _rewrite(from.path, to.path);
  }

  Future<RepointResult> _rewrite(String from, String to) async {
    final planned = <_Rewrite>[];
    var rows = 0;
    for (final name in _files) {
      switch (await _plan(name, from, to)) {
        case _Keep():
          continue;
        case _Refused(:final result):
          return result;
        case final _Rewrite rewrite:
          planned.add(rewrite);
          rows += rewrite.rowsChanged;
      }
    }
    if (planned.isEmpty) return const NothingToRepoint();
    return _commit(planned, rows);
  }

  Future<_Plan> _plan(String name, String from, String to) async {
    final file = File(p.join(documents.path, name));
    final String text;
    try {
      if (!await file.exists()) return const _Keep();
      text = await file.readAsString();
    } on FileSystemException catch (error) {
      log.e('read $name to repoint $from', error);
      return _Refused(IoFailure(_detail(error)));
    } on FormatException catch (error) {
      log.e('read $name to repoint $from', error);
      return const _Refused(IoFailure(_notText));
    }
    // A file with no records is one the user has not trained against yet.
    if (text.trim().isEmpty) return const _Keep();
    if (name == _attempts) return _planAttempts(text, from, to);
    return _planText(text, name, from, to);
  }

  Future<RepointResult> _commit(List<_Rewrite> planned, int rows) async {
    final operation =
        '${DateTime.now().microsecondsSinceEpoch}-'
        '${Random.secure().nextInt(1 << 32).toRadixString(16)}';
    try {
      await removeStaleTemporaries(documents);
      for (final file in planned) {
        await _keepReplaced(file, operation);
      }
      for (final file in planned) {
        await replaceFile(
          p.join(documents.path, file.name),
          utf8.encode(file.text),
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
  Future<void> _keepReplaced(_Rewrite file, String operation) async {
    final kept = p.join(documents.path, _replacedFolder, operation, file.name);
    await Directory(p.dirname(kept)).create(recursive: true);
    await createFileExclusively(kept, utf8.encode(file.original));
  }
}

sealed class RepointResult {
  const RepointResult();
}

/// [rowsChanged] rows across the three files now name the new path.
final class Repointed extends RepointResult {
  const Repointed(this.rowsChanged);

  final int rowsChanged;
}

/// No row named the old path, so no file was written.
final class NothingToRepoint extends RepointResult {
  const NothingToRepoint();
}

/// A record in [file] at [line] is not the shape the schema describes.
///
/// Nothing was written. A training file is a user's whole review history, and
/// a record nobody can read is not one to replace with defaults.
final class Malformed extends RepointResult {
  const Malformed(this.file, this.line);

  /// The file's name, such as `repertoire_reviews.csv`.
  final String file;

  /// Counting from one, as an editor numbers lines.
  final int line;
}

/// The records could not be read or written. They are as they were.
final class IoFailure extends RepointResult {
  const IoFailure(this.detail);

  /// For the log; the widget writes the sentence.
  final String detail;
}

/// These four files, and only these: a legacy `<name>.pre-csv-v2.bak` holds
/// the bytes from before the quoting migration and is never rewritten.
const _files = [
  'repertoire_reviews.csv',
  'repertoire_move_progress.csv',
  'repertoire_review_history.csv',
  _attempts,
];

/// The log of answered moves: one JSON object per line, only ever appended.
const _attempts = 'repertoire_move_attempts.jsonl';

/// Where the old app keeps what a relocation replaced, under Documents, one
/// folder per operation. Both apps read it, so the name and the shape stay
/// as they are.
const _replacedFolder = '.cap-reference-history';

/// The first column of every one of the three CSVs, and of their headers.
const _idColumn = 'repertoire_id';

/// What the attempt log calls the same thing.
const _attemptIdKey = 'repertoireId';

const _notText = 'the file is not UTF-8 text';

/// What one file needs, decided without touching the disk.
sealed class _Plan {
  const _Plan();
}

final class _Keep extends _Plan {
  const _Keep();
}

final class _Rewrite extends _Plan {
  const _Rewrite({
    required this.name,
    required this.original,
    required this.text,
    required this.rowsChanged,
  });

  /// The file's name, such as `repertoire_reviews.csv`.
  final String name;

  /// What the file holds now, kept before the rewrite replaces it.
  final String original;

  final String text;
  final int rowsChanged;
}

final class _Refused extends _Plan {
  const _Refused(this.result);

  final RepointResult result;
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
/// not name this chapter keeps the bytes it was written with.
_Plan _planAttempts(String text, String from, String to) {
  final lines = text.split('\n');
  var rows = 0;
  for (var i = 0; i < lines.length; i++) {
    final rewritten = _movedAttempt(lines[i], from, to);
    if (rewritten == null) return _Refused(Malformed(_attempts, i + 1));
    if (rewritten != lines[i]) rows++;
    lines[i] = rewritten;
  }
  if (rows == 0) return const _Keep();
  return _Rewrite(
    name: _attempts,
    original: text,
    text: lines.join('\n'),
    rowsChanged: rows,
  );
}

/// One logged answer pointing at its chapter, or null when the line is not
/// a JSON object naming one — which is a file this code will not rewrite.
String? _movedAttempt(String line, String from, String to) {
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
  final moved = _moved(id, from, to);
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
  final width = _headerWidth(records);
  // Without the header there is no way to tell a pre-v2 record whose path
  // held commas from a record with the wrong number of fields.
  if (width == null) return _Refused(Malformed(name, 1));
  final out = StringBuffer();
  var rows = 0;
  for (final record in records) {
    final cells = _dataCells(record, width);
    if (cells != null && cells.length != width) {
      return _Refused(Malformed(name, record.line));
    }
    final text = cells == null
        ? record.source
        : _rewritten(record, cells, from, to);
    if (text != record.source) rows++;
    out
      ..write(text)
      ..write(record.terminator);
  }
  if (rows == 0) return const _Keep();
  return _Rewrite(
    name: name,
    original: text,
    text: out.toString(),
    rowsChanged: rows,
  );
}

/// The cells of a record that names a chapter, or null for the header and
/// for blank lines, which pass through untouched.
List<String>? _dataCells(CsvRecord record, int width) {
  if (record.isBlank || record.fields.first == _idColumn) return null;
  return record.source.startsWith('"')
      ? record.fields
      : _rejoinLegacyPath(record.fields, width);
}

String _rewritten(
  CsvRecord record,
  List<String> cells,
  String from,
  String to,
) {
  final moved = _moved(cells.first, from, to);
  if (moved == null) return record.source;
  return encodeCsvRecord([moved, ...cells.skip(1)]);
}

/// The old app's matching rule, which this one must agree with exactly.
String? _moved(String path, String from, String to) {
  if (p.equals(path, from)) return to;
  if (p.isWithin(from, path)) return p.join(to, p.relative(path, from: from));
  return null;
}

/// The width the header declares, or null when the file has no header.
int? _headerWidth(List<CsvRecord> records) {
  for (final record in records) {
    if (record.isBlank) continue;
    return record.fields.first == _idColumn ? record.fields.length : null;
  }
  return null;
}

/// Writers before the quoting migration put the chapter path in unquoted,
/// commas and all, so a path with a comma spilled into the columns after it.
/// Every later column has a fixed position, so the path is whatever is left
/// once they are accounted for.
List<String> _rejoinLegacyPath(List<String> cells, int width) {
  if (cells.length <= width) return cells;
  final spilled = cells.length - width + 1;
  return [cells.take(spilled).join(','), ...cells.skip(spilled)];
}

String _detail(Object error) => error is FileSystemException
    ? error.osError?.message ?? error.message
    : '$error';

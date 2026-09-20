/// The CSV dialect the training files are written in, plus the one thing
/// `package:csv` cannot tell a caller: which characters each record occupied.
///
/// A rewrite that only changes one column must hand every other record back
/// unaltered, down to the byte. Re-encoding a whole file canonically would
/// change rows nobody asked about — a row quoted more than it had to be, a
/// stray carriage return — so each record keeps its own source text and only
/// the records that change are encoded again.
///
/// Splitting records is not the same job as reading fields: a newline inside
/// a quoted field is part of the record. Hence the scan below, over the
/// package's decoder for the fields themselves and its encoder for the rows
/// that are written again, so both apps read and write one dialect.
library;

import 'package:csv/csv.dart';

/// Line feeds, not carriage returns: what the old app writes into these
/// files, and the two apps share them on one profile.
final _dialect = Csv(autoDetect: false, lineDelimiter: '\n');

/// One record, its fields, and the exact text it occupied.
final class CsvRecord {
  const CsvRecord({
    required this.fields,
    required this.source,
    required this.terminator,
    required this.line,
  });

  /// The decoded cells, empty for a blank line.
  final List<String> fields;

  /// The record as it stood in the file, without its line terminator.
  final String source;

  /// `\n`, `\r\n`, or empty for a last record with no trailing newline.
  final String terminator;

  /// Where the record starts, counting from one, for a report to the user.
  final int line;

  bool get isBlank => fields.isEmpty;
}

sealed class CsvRead {
  const CsvRead();
}

final class CsvParsed extends CsvRead {
  const CsvParsed(this.records);

  final List<CsvRecord> records;
}

/// The text is not CSV. Nothing is guessed and nothing is dropped.
final class CsvUnreadable extends CsvRead {
  const CsvUnreadable(this.line, this.detail);

  final int line;

  /// For the log; the widget writes the sentence.
  final String detail;
}

/// Reads [text] as records, each remembering the characters it came from.
CsvRead readCsvRecords(String text) {
  final records = <CsvRecord>[];
  var start = 0;
  var startLine = 1;
  var line = 1;
  var quoted = false;
  for (var i = 0; i < text.length; i++) {
    if (text[i] == '"') quoted = !quoted;
    if (text[i] != '\n') continue;
    line++;
    if (quoted) continue;
    final crlf = i > start && text[i - 1] == '\r';
    final source = text.substring(start, crlf ? i - 1 : i);
    final record = _record(source, crlf ? '\r\n' : '\n', startLine);
    if (record == null) return CsvUnreadable(startLine, _oneRecord);
    records.add(record);
    start = i + 1;
    startLine = line;
  }
  if (quoted) return CsvUnreadable(startLine, _unclosed);
  if (start == text.length) return CsvParsed(records);
  final last = _record(text.substring(start), '', startLine);
  if (last == null) return CsvUnreadable(startLine, _oneRecord);
  return CsvParsed(records..add(last));
}

/// One record as a line of CSV, without a terminator.
String encodeCsvRecord(List<String> fields) => _dialect.encode([fields]);

const _oneRecord = 'that line is not one CSV record';
const _unclosed = 'a quoted field is never closed';

CsvRecord? _record(String source, String terminator, int line) {
  if (source.trim().isEmpty) {
    return CsvRecord(
      fields: const [],
      source: source,
      terminator: terminator,
      line: line,
    );
  }
  // The decoder reports a top type per cell; these files hold text only.
  final List<List<Object?>> rows = _dialect.decode(source);
  if (rows.length != 1) return null;
  return CsvRecord(
    fields: [for (final cell in rows.single) cell?.toString() ?? ''],
    source: source,
    terminator: terminator,
    line: line,
  );
}

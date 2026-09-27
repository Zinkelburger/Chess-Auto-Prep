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
  final splitter = _RecordSplitter(text);
  final unclosed = splitter.split();
  if (unclosed != null) return CsvUnreadable(unclosed, _unclosed);
  final records = <CsvRecord>[];
  for (final span in splitter.spans) {
    final source = text.substring(span.start, span.end);
    final record = _record(source, span.terminator, span.line);
    if (record == null) return CsvUnreadable(span.line, _oneRecord);
    records.add(record);
  }
  return CsvParsed(records);
}

/// The characters one record occupies, and the line it starts on.
typedef _Span = ({int start, int end, String terminator, int line});

/// Where one record ends and the next begins.
///
/// RFC 4180 decides when a double quote opens a field: only at the start of
/// one. Everywhere else in an unquoted field it is an ordinary character, so
/// `/chess/My "KID" line.pgn` is a path and not the beginning of a quoted
/// field that swallows the rest of the file. Inside a quoted field `""` is a
/// quote and a lone `"` closes the field, after which a line feed ends the
/// record as it does anywhere else.
final class _RecordSplitter {
  _RecordSplitter(this.text);

  final String text;
  final spans = <_Span>[];
  var _start = 0;
  var _startLine = 1;
  var _line = 1;
  var _quoted = false;
  var _fieldStart = true;

  /// The line a quoted field was opened on and never closed, or null when
  /// every record ends where the text says it does.
  int? split() {
    for (var i = 0; i < text.length; i++) {
      final char = text[i];
      if (char == '\n') _line++;
      if (_quoted) {
        i = _inQuotes(i);
      } else if (char == '"' && _fieldStart) {
        _quoted = true;
      } else if (char == ',') {
        _fieldStart = true;
      } else if (char == '\n') {
        _end(i);
      } else {
        _fieldStart = false;
      }
    }
    if (_quoted) return _startLine;
    if (_start < text.length) _end(text.length);
    return null;
  }

  /// The last index this call consumed at [i], which is inside a quoted
  /// field: one more when `""` spells a quote, [i] itself otherwise.
  int _inQuotes(int i) {
    if (text[i] != '"') return i;
    if (i + 1 < text.length && text[i + 1] == '"') return i + 1;
    _quoted = false;
    _fieldStart = false;
    return i;
  }

  /// Closes the record at [newline], which is the line feed that ends it or,
  /// for a last record written without one, the end of the text.
  void _end(int newline) {
    final crlf =
        newline < text.length && newline > _start && text[newline - 1] == '\r';
    spans.add((
      start: _start,
      end: crlf ? newline - 1 : newline,
      terminator: newline == text.length
          ? ''
          : crlf
          ? '\r\n'
          : '\n',
      line: _startLine,
    ));
    _start = newline + 1;
    _startLine = _line;
    _fieldStart = true;
  }
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

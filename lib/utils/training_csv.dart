/// The CSV dialect of the training progress file, and its one format quirk.
library;

import 'package:csv/csv.dart';

final _csv = Csv(autoDetect: false, lineDelimiter: '\n');

/// The header cell that opens the training file's column row.
const _headerFirstCell = 'repertoire_id';

/// One record as a single CSV line without its trailing newline.
String encodeTrainingRow(List<String> cells) {
  final encoded = _csv.encode([cells]);
  return encoded.endsWith('\n')
      ? encoded.substring(0, encoded.length - 1)
      : encoded;
}

/// The cells of one record that must have exactly [columns] fields.
///
/// A row that is *not* quoted and still has too many cells is a pre-v2
/// record whose repertoire path contained commas; see [_rejoinUnquotedPath].
List<String> decodeTrainingRow(String row, int columns) {
  final rows = _csv.decode(row);
  if (rows.length != 1) {
    throw const FormatException('Expected one training record');
  }
  final cells = _cellsOf(rows.single);
  if (row.startsWith('"')) return cells;
  return _rejoinUnquotedPath(cells, columns);
}

/// Every record line of the file, re-encoded canonically, header dropped.
///
/// The header row's width is what tells a pre-v2 record apart from a
/// well-formed one, so it is consumed rather than returned.
List<String> trainingRows(String? content) {
  if (content == null || content.trim().isEmpty) return [];
  final result = <String>[];
  int? width;
  for (final row in _csv.decode(content)) {
    if (row.isEmpty) continue;
    if (row.first == _headerFirstCell) {
      width = row.length;
      continue;
    }
    final cells = _cellsOf(row);
    result.add(
      encodeTrainingRow(
        width == null ? cells : _rejoinUnquotedPath(cells, width),
      ),
    );
  }
  return result;
}

List<String> _cellsOf(List<dynamic> row) =>
    row.map((cell) => cell.toString()).toList();

/// Pre-v2 writers emitted the repertoire path without quoting it. The
/// remaining fields have fixed positions and generated line IDs, so a
/// comma-containing path can be reconstructed from the leftmost columns.
List<String> _rejoinUnquotedPath(List<String> cells, int columns) {
  if (cells.length <= columns) return cells;
  final pathColumns = cells.length - columns + 1;
  return [cells.take(pathColumns).join(','), ...cells.skip(pathColumns)];
}

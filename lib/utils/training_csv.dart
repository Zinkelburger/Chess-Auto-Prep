import 'package:csv/csv.dart';

final _csv = Csv(autoDetect: false, lineDelimiter: '\n');

String encodeTrainingRow(List<String> cells) {
  final encoded = _csv.encode([cells]);
  return encoded.endsWith('\n')
      ? encoded.substring(0, encoded.length - 1)
      : encoded;
}

List<String> decodeTrainingRow(String row, int columns) {
  final rows = _csv.decode(row);
  if (rows.length != 1) {
    throw const FormatException('Expected one training record');
  }
  final cells = rows.single.map((cell) => cell.toString()).toList();
  // Pre-v2 writers emitted the repertoire path without quoting it. The
  // remaining fields have fixed positions and generated line IDs, so a
  // comma-containing path can be reconstructed from the leftmost columns.
  if (cells.length > columns && !row.startsWith('"')) {
    final pathColumns = cells.length - columns + 1;
    return [cells.take(pathColumns).join(','), ...cells.skip(pathColumns)];
  }
  return cells;
}

List<String> trainingRows(String? content) {
  if (content == null || content.trim().isEmpty) return [];
  final decoded = _csv.decode(content);
  final result = <String>[];
  int? width;
  for (final row in decoded) {
    if (row.isEmpty) continue;
    if (row.first == 'repertoire_id') {
      width = row.length;
      continue;
    }
    final cells = row.map((cell) => cell.toString()).toList();
    if (width != null && cells.length > width) {
      final pathColumns = cells.length - width + 1;
      result.add(
        encodeTrainingRow([
          cells.take(pathColumns).join(','),
          ...cells.skip(pathColumns),
        ]),
      );
    } else {
      result.add(encodeTrainingRow(cells));
    }
  }
  return result;
}

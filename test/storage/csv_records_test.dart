// Records split from the training CSVs, each keeping the bytes it came from.
import 'package:chess_auto_prep/storage/csv_records.dart';
import 'package:chess_auto_prep/storage/training_rows.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a record of empty cells is a blank line, as the old app reads it, '
      'and keeps its bytes', () {
    const text = 'a,b\n,,,\n"",""\r\nc,d\n';
    final records = (readCsvRecords(text) as CsvParsed).records;
    expect(records.map((r) => r.isBlank), [false, true, true, false]);
    expect(records.map((r) => (r.source, r.terminator)).skip(1).take(2), [
      (',,,', '\n'),
      ('"",""', '\r\n'),
    ]);
    expect(records.map((r) => '${r.source}${r.terminator}').join(), text);
  });

  test('a blank review line takes the header width', () {
    final blank = (readCsvRecords('\n') as CsvParsed).records.single;
    expect(rowWidth(reviewsFile, blank, 11), 11);
  });
}

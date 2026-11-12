// Records split from the training CSVs, each keeping the bytes it came from.
import 'package:chess_auto_prep/storage/csv_records.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a record of empty cells is a blank line, as existing files hold it, '
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

  List<CsvRecord> records(String text) =>
      (readCsvRecords(text) as CsvParsed).records;

  test('a quoted field that opens the file may hold a line feed', () {
    final read = records('"first\nline",x\nnext,y\n');
    expect(read.map((r) => r.fields), [
      ['first\nline', 'x'],
      ['next', 'y'],
    ]);
  });

  test('a quote inside an unquoted field is an ordinary character', () {
    final read = records('a,My "KID line.pgn\nb,c\n');
    expect(read.map((r) => r.source), ['a,My "KID line.pgn', 'b,c']);
  });

  test('a quoted field may end the text with no line feed', () {
    final read = records('a,"b"');
    expect(read.single.fields, ['a', 'b']);
    expect(read.single.terminator, '');
  });

  test('a doubled quote inside a quoted field does not close it', () {
    final read = records('"say ""hi""\nthen",x\nnext,y\n');
    expect(read.map((r) => r.fields), [
      ['say "hi"\nthen', 'x'],
      ['next', 'y'],
    ]);
  });
}

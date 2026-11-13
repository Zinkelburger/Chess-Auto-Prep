import 'package:chess_auto_prep/chess/training/records.dart';
import 'package:chess_auto_prep/chess/training/schedule.dart';
import 'package:chess_auto_prep/storage/csv_records.dart';
import 'package:chess_auto_prep/storage/training_rows.dart';
import 'package:flutter_test/flutter_test.dart';

const _source = '/home/u/Documents/repertoires/KID/Main.pgn';

List<CsvRecord> _records(String text) =>
    (readCsvRecords(text) as CsvParsed).records;

void main() {
  test('a review row is written with two decimals and read back cell by '
      'cell', () {
    final review = Review(
      key: (source: _source, id: 'a'),
      lineName: 'Main line',
      ease: 2.3,
      intervalDays: 3.25,
      due: DateTime.utc(2026, 11, 20),
      lastRating: 'good',
      lastReviewed: DateTime.utc(2026, 11, 12, 9),
      passes: 4,
      fails: 1,
      excluded: true,
    );
    final cells = encodeReview(review);
    expect(cells, [
      _source,
      'a',
      'Main line',
      '2.30',
      '3.25',
      '2026-11-20T00:00:00.000Z',
      'good',
      '2026-11-12T09:00:00.000Z',
      '4',
      '1',
      'true',
    ]);
    final read = decodeReview(cells)!;
    expect(read.lineName, 'Main line');
    expect(read.due, DateTime.utc(2026, 11, 20));
    expect(read.lastReviewed, DateTime.utc(2026, 11, 12, 9));
    expect(read, review);
  });

  test('a streak row is read cell by cell', () {
    expect(
      decodeStreak([_source, 'a', '6', '3', '1']),
      const MoveStreak(
        key: (source: _source, id: 'a'),
        ply: 6,
        streak: 3,
        learned: true,
      ),
    );
  });

  test('the header and blank lines carry no cells', () {
    final records = _records('$streaksHeader\n\n$_source,a,0,1,1\n');
    expect(
      [for (final record in records) dataCells(record)],
      [
        null,
        null,
        [_source, 'a', '0', '1', '1'],
      ],
    );
  });

  test('a path is found only whole, in any of its spellings', () {
    expect(
      mayName(r'"C:\\Users\\me\\KID.pgn",a', r'C:\Users\me\KID.pgn'),
      isTrue,
    );
    expect(mayName('/a/b.pgn,a', '/a/b.pgn'), isTrue);
    expect(mayName('ka/b.pgn,a', '/a/b.pgn'), isFalse);
    expect(mayName('/a/b.pgx,a', '/a/b.pgn'), isFalse);
  });
}

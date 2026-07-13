import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/services/opening_book_service.dart';
import 'package:chess_auto_prep/services/pgn_parsing_service.dart';

const _tsv = '''
eco	name	pgn
A56	Benoni Defense	1. d4 Nf6 2. c4 c5
A43	Old Benoni Defense	1. d4 c5
B20	Sicilian Defense	1. e4 c5
B27	Sicilian Defense: Hyperaccelerated Dragon	1. e4 c5 2. Nf3 g6
''';

({Map<String, String> headers, String pgnText}) _game(String movetext) =>
    (headers: <String, String>{}, pgnText: '[Event "?"]\n\n$movetext *');

void main() {
  final book = OpeningBook(buildOpeningBookFromTsv([_tsv]));

  test('parses TSV lines, skipping the column header', () {
    expect(book.byFen.length, 4);
    expect(book.byFen.values.map((e) => e.name),
        contains('Benoni Defense'));
  });

  test('classifies by position, so transposed move orders match', () {
    final games = [
      _game('1. d4 Nf6 2. c4 c5'), // book move order
      _game('1. c4 c5 2. d4 Nf6'), // same position, different order
      _game('1. Nf3 d5 2. g3 Bg4'), // no book position beyond none listed
    ];
    final index = buildFenIndex(games);
    final result = classifyGamesFromIndex(book, index, games.length);

    expect(result[0]?.name, 'Benoni Defense');
    expect(result[1]?.name, 'Benoni Defense');
    expect(result[2], isNull);
  });

  test('deepest book match wins over shallower ones', () {
    final games = [
      _game('1. e4 c5 2. Nf3 g6 3. c3 Bg7'),
    ];
    final index = buildFenIndex(games);
    final result = classifyGamesFromIndex(book, index, games.length);

    expect(result[0]?.name, 'Sicilian Defense: Hyperaccelerated Dragon');
    expect(result[0]?.eco, 'B27');
  });
}

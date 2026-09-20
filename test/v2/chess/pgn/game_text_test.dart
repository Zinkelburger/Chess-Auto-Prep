import 'package:chess_auto_prep/v2/chess/pgn/game_text.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/chess/pgn/pgn_reader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('an escaped quote does not end a value, and the tags below it '
      'survive', () {
    const game =
        '[Event "A"]\n'
        '[White "He said \\"hi\\""]\n'
        '[Result "1-0"]\n'
        '[LineID "line_abc"]\n'
        '\n'
        '1. e4 1-0';
    final header = readTags(game);
    expect(tagValue(header, 'White'), r'He said \"hi\"');
    expect(tagValue(header, 'Result'), '1-0');
    expect(tagValue(header, 'LineID'), 'line_abc');
  });

  test('the keys and values real exports carry are read as they are', () {
    const game =
        '[WhiteElo "2412"]\n'
        '[ECO "B90"]\n'
        '[Date "????.??.??"]\n'
        '[Result "0-1"]\n'
        '\n'
        '1. e4 0-1';
    final header = readTags(game);
    expect(tagValue(header, 'WhiteElo'), '2412');
    expect(tagValue(header, 'ECO'), 'B90');
    expect(tagValue(header, 'Date'), '????.??.??');
    expect(tagValue(header, 'Result'), '0-1');
  });

  test('a line that is not a tag is kept, and the tags below it with it', () {
    final header = readTags(_withStrayLines);
    expect(header.map((line) => line.text), [
      '[Event "A"]',
      '%an escape the reader does not know',
      '[Malformed "unclosed]',
      '[Result "*"]',
      '[LineID "line_abc"]',
    ]);
    expect(header.whereType<UnparsedHeader>(), hasLength(2));
    expect(tagValue(header, 'LineID'), 'line_abc');
  });

  test('the header stops at the movetext, blank line or not', () {
    final header = readTags('[Event "A"]\n1. e4 *');
    expect(header.map((line) => line.text), ['[Event "A"]']);
  });

  test('a game read and written again keeps its escapes', () {
    const game =
        '[Event "A"]\n'
        '[White "He said \\"hi\\""]\n'
        '[Result "*"]\n'
        '\n'
        '1. e4 *';
    expect(writeGameText(readTags(game), _treeOf(game)), game);
  });

  test('writing puts a line the reader could not parse back unchanged', () {
    expect(
      writeGameText(readTags(_withStrayLines), _treeOf(_withStrayLines)),
      _withStrayLines,
    );
  });
}

const _withStrayLines =
    '[Event "A"]\n'
    '%an escape the reader does not know\n'
    '[Malformed "unclosed]\n'
    '[Result "*"]\n'
    '[LineID "line_abc"]\n'
    '\n'
    '1. e4 *';

/// The tree of the one game in [text], so a written game can be compared with
/// the file it came from.
GameTree _treeOf(String text) => readPgn(text).games.single.tree;

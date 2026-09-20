import 'package:chess_auto_prep/v2/chess/pgn/game_text.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/chess/pgn/pgn_reader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a tab after [Event still starts a game', () {
    const file = '[Event\t"A"]\n[Result "*"]\n\n1. e4 *\n';
    final document = splitChapterText(file);
    expect(document.preamble, isEmpty);
    expect(document.games, hasLength(1));
  });

  test('[EventDate does not start a game', () {
    const file = '[Event "A"]\n[EventDate "2020.01.01"]\n\n1. e4 *\n';
    expect(splitChapterText(file).games, hasLength(1));
  });

  test('a header quoted inside a comment does not split the game', () {
    const file =
        '[Event "A"]\n'
        '[Result "*"]\n'
        '\n'
        '1. e4 {The file said\n'
        '[Event "B"] and meant nothing by it\n'
        '} *\n';
    final document = splitChapterText(file);
    expect(document.games, hasLength(1));
    expect(document.games.single.text, contains('and meant nothing by it'));
  });

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
    expect(tagValue(header, 'White'), 'He said "hi"');
    expect(tagValue(header, 'Result'), '1-0');
    expect(tagValue(header, 'LineID'), 'line_abc');
  });

  test('an escaped backslash reads as one backslash', () {
    final header = readTags('[Site "C:\\\\games"]\n[Result "*"]\n\n*');
    expect(tagValue(header, 'Site'), r'C:\games');
    expect(tagValue(header, 'Result'), '*');
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

  test('a game read and written again is the same bytes', () {
    const game =
        '[Event "A"]\n'
        '[White "He said \\"hi\\""]\n'
        '[Site "C:\\\\games"]\n'
        '[Result "*"]\n'
        '\n'
        '1. e4 *';
    expect(writeGameText(readTags(game), _treeOf(game)), game);
  });

  test('a value set with a quote in it does not cut the header off', () {
    const header = [
      PgnTag('Event', 'He said "go"'),
      PgnTag('Result', '*'),
      PgnTag('LineID', 'line_abc'),
    ];
    final written = writeGameText(header, _treeOf('[Event "A"]\n\n1. e4 *'));
    expect(readTags(written).map((line) => line.text), [
      r'[Event "He said \"go\""]',
      '[Result "*"]',
      '[LineID "line_abc"]',
    ]);
    expect(tagValue(readTags(written), 'Event'), 'He said "go"');
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
GameTree _treeOf(String text) => readGame(text).tree!;

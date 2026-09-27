import 'package:chess_auto_prep/v2/chess/pgn/game_text.dart';
import 'package:chess_auto_prep/v2/chess/pgn/pgn_reader.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/pgn_round_trip.dart';

/// One game read and written again, which is what a chapter does to the one
/// game an edit touched.
String rewrite(String game) {
  final read = readGame(game);
  return writeGameText(
    read.tags,
    read.tree!,
    terminator: read.terminator,
    separator: read.separator,
  );
}

List<PgnHeader> headerOf(String game) => readGame(game).tags;

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
    final header = headerOf(game);
    expect(tagValue(header, 'White'), 'He said "hi"');
    expect(tagValue(header, 'Result'), '1-0');
    expect(tagValue(header, 'LineID'), 'line_abc');
  });

  test('an escaped backslash reads as one backslash', () {
    final header = headerOf('[Site "C:\\\\games"]\n[Result "*"]\n\n*');
    expect(tagValue(header, 'Site'), r'C:\games');
    expect(tagValue(header, 'Result'), '*');
  });

  test('a backslash that escapes nothing keeps both its characters', () {
    final header = headerOf('[Site "a\\nb"]\n[Result "*"]\n\n*');
    expect(tagValue(header, 'Site'), r'a\nb');
  });

  test('the keys and values real exports carry are read as they are', () {
    const game =
        '[WhiteElo "2412"]\n'
        '[ECO "B90"]\n'
        '[Date "????.??.??"]\n'
        '[Result "0-1"]\n'
        '\n'
        '1. e4 0-1';
    final header = headerOf(game);
    expect(tagValue(header, 'WhiteElo'), '2412');
    expect(tagValue(header, 'ECO'), 'B90');
    expect(tagValue(header, 'Date'), '????.??.??');
    expect(tagValue(header, 'Result'), '0-1');
  });

  test('a value holding a whole movetext stays one value', () {
    final header = headerOf(
      '[SourceMovetext "1. e4 c5 2. Nf3 d6"]\n[Result "*"]\n\n1. d4 *',
    );
    expect(tagValue(header, 'SourceMovetext'), '1. e4 c5 2. Nf3 d6');
    expect(tagValue(header, 'Result'), '*');
    expect(
      readGame('[SourceMovetext "1. e4 c5"]\n\n1. d4 *').tree!.children,
      hasLength(1),
    );
  });

  test('a tag named twice keeps both lines and reads as the first', () {
    const game = '[Result "1-0"]\n[Result "0-1"]\n\n1. e4 1-0';
    expect(headerOf(game), hasLength(2));
    expect(tagValue(headerOf(game), 'Result'), '1-0');
    expect(rewrite(game), game);
  });

  test('two tags on one line stay on one line and keep both values', () {
    const game = '[Event "A"] [Site "B"]\n\n1. e4 *';
    final header = headerOf(game);
    expect(tagValue(header, 'Event'), 'A');
    expect(tagValue(header, 'Site'), 'B');
    expect(rewrite(game), game);
  });

  test('a tag value keeps the backslash the file wrote', () {
    // The standard says to escape it; tidying it would change bytes the
    // edit never touched.
    const game = '[Event "a\\b"]\n\n1. e4 *';
    expect(tagValue(headerOf(game), 'Event'), r'a\b');
    expect(rewrite(game), game);
  });

  test('trailing space after a tag line survives', () {
    const game = '[Event "A"]  \n[Result "*"]\n\n1. e4 *';
    expect(rewrite(game), game);
  });

  test('a game with its moves on the header line gains no newline', () {
    expectExactRoundTrip('[Event "a"] 1. e4 *');
  });

  test('a header and a move number with no move writes the same twice', () {
    const game = '[Event "a"]\n\n1. ';
    final once = rewrite(game);
    expect(rewrite(once), once);
  });

  test('a line that is not a tag is kept, and the tags below it with it', () {
    final header = headerOf(_withStrayLines);
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
    final header = headerOf('[Event "A"]\n1. e4 *');
    expect(header.map((line) => line.text), ['[Event "A"]']);
  });

  test('moves on the header line are still moves', () {
    final read = readGame('[Event "A"] 1. e4 e5 *');
    expect(read.tree!.children.single.san, 'e4');
    expect(read.terminator, '*');
  });

  test('a game read and written again is the same bytes', () {
    const game =
        '[Event "A"]\n'
        '[White "He said \\"hi\\""]\n'
        '[Site "C:\\\\games"]\n'
        '[Result "*"]\n'
        '\n'
        '1. e4 *';
    expect(rewrite(game), game);
  });

  test('a game whose header lines end in CRLF keeps them', () {
    const game = '[Event "A"]\r\n[Result "*"]\r\n\n1. e4 *';
    expect(rewrite(game), game);
  });

  test('a value set with a quote in it does not cut the header off', () {
    const header = [
      PgnTag('Event', 'He said "go"'),
      PgnTag('Result', '*'),
      PgnTag('LineID', 'line_abc'),
    ];
    final written = writeGameText(
      header,
      readGame('[Event "A"]\n\n1. e4 *').tree!,
      terminator: '*',
      separator: '\n',
    );
    expect(headerOf(written).map((line) => line.text), [
      r'[Event "He said \"go\""]',
      '[Result "*"]',
      '[LineID "line_abc"]',
    ]);
    expect(tagValue(headerOf(written), 'Event'), 'He said "go"');
  });

  test('writing puts a line the reader could not parse back unchanged', () {
    expect(rewrite(_withStrayLines), _withStrayLines);
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

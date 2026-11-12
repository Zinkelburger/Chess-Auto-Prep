import 'package:chess_auto_prep/chess/bughouse/bpgn_moves.dart';
import 'package:chess_auto_prep/chess/bughouse/table.dart';
import 'package:chess_auto_prep/chess/bughouse/table_game.dart';
import 'package:chess_auto_prep/chess/bughouse/table_line.dart';
import 'package:flutter_test/flutter_test.dart';

/// A FICS game as bughouse-db.org publishes it: two tags to a line, a
/// banner comment, a clock after every move and how it ended.
const fics =
    '[Event "FICS rated bughouse game"]\r\n'
    '[Site "FICS - freechess.org"]\r\n'
    '[Date "2023.12.13"]\r\n'
    '[WhiteA "larso"][WhiteAElo "2121"]\r\n'
    '[BlackA "chewchewtrain"][BlackAElo "1916"]\r\n'
    '[WhiteB "blitzbullet"][WhiteBElo "2752"]\r\n'
    '[BlackB "GuestXYZ"][BlackBElo "0"]\r\n'
    '[TimeControl "120+0"]\r\n'
    '[Result "0-1"]\r\n'
    '\r\n'
    '{C:This is game number 3720947 at http://www.bughouse-db.org}\r\n'
    '1A. e4{119.000} 1B. d4{118.000} 1b. d5{120.000} 1a. d5{115.500} '
    '2A. exd5{117.250} 2B. Nf3{118.000} 2b. P@e4{9.400} \r\n'
    '{GuestXYZ checkmated} 0-1\r\n';

/// What the arena writes now: the opening in the movetext and still in
/// its tag, each move's clock among its other notes.
const arena =
    '[Event "Hivemind Arena"]\n[Round "3"]\n'
    '[WhiteA "hb-v4"]\n[BlackA "hm-n1500"]\n'
    '[WhiteB "hm-n1500"]\n[BlackB "hb-v4"]\n'
    '[TimeControl "120"]\n[Opening "1e2e4 1d7d5"]\n'
    '[Result "1-0"]\n[Termination "checkmate"]\n\n'
    '1A. e4 1a. d5 2A. exd5 {[%clk 0:01:58.1] [%eval 3.19] 1.9s} '
    '1B. Nf3 {[%clk 0:01:58.0] 2.0s}\n'
    '{A-black sits @3.0s} 1b. P@e4 {[%clk 0:01:57.5] [%eval #-2] 4.0s} 1-0\n';

/// What the arena wrote before: the opening only in its tag, the movetext
/// after it in coordinates, numbered from 1 again.
const oldArena =
    '[Event "Hivemind Arena"]\n[Round "1"]\n'
    '[WhiteA "hb-v4"]\n[BlackA "hm-n1500"]\n'
    '[WhiteB "hm-n1500"]\n[BlackB "hb-v4"]\n'
    '[TimeControl "120"]\n'
    '[Opening "1e2e4 2d2d4 1d7d5 2e7e5"]\n'
    '[Result "0-1"]\n[Termination "flag"]\n\n'
    '1A. e4d5 {1.9s 118.1} 1B. d4e5 {2.1s 117.9} 1a. d8d5 {3.7s 118.3} '
    '{B-black sits @4.2s} 1b. P@d2 {5.0s 115.0} 2B. e1d2 {6.5s 116.4} 0-1\n';

PastedLine read(String text) => readTableLineText(text) as PastedLine;

List<String> sans(TableLine line) => [for (final m in line.moves) m.san];

void main() {
  test('a FICS game gives its players, ratings, clocks and ending', () {
    final PastedLine(:line, :game) = read(fics);
    expect(sans(line), ['e4', 'd4', 'd5', 'd5', 'exd5', 'Nf3', 'P@e4']);
    expect(game!.name(Seat.a), 'larso');
    expect(game.name(Seat.c), 'chewchewtrain');
    expect(game.name(Seat.d), 'blitzbullet');
    expect(game.name(Seat.b), 'GuestXYZ');
    expect(game.rating(Seat.a), '2121');
    expect(game.rating(Seat.b), isNull, reason: 'FICS rates a guest 0');
    expect(game.startClock, const Duration(minutes: 2));
    expect(game.winner, Team.cd);
    expect(game.ending, 'GuestXYZ checkmated');
    expect(
      game.heading,
      'C + D won · GuestXYZ checkmated · FICS rated bughouse game · 2023.12.13',
    );
    expect(
      [for (final m in line.moves) m.clock?.inMilliseconds],
      [119000, 118000, 120000, 115500, 117250, 118000, 9400],
    );
  });

  test('a seat\'s clock is the one after its last move on the boards', () {
    final line = read(fics).line;
    expect(line.clock(Seat.a), const Duration(milliseconds: 117250));
    expect(line.clock(Seat.c), const Duration(milliseconds: 115500));
    expect(line.clock(Seat.d), const Duration(seconds: 118));
    expect(line.clock(Seat.b), const Duration(milliseconds: 9400));
    final start = line.atStart;
    for (final seat in Seat.values) {
      expect(start.clock(seat), isNull, reason: '${seat.letter} has not moved');
    }
    // Board 1 after 1.e4 alone: A has moved, C has not.
    final first = start.goTo(BoardNumber.one, 0);
    expect(first.clock(Seat.a), const Duration(seconds: 119));
    expect(first.clock(Seat.c), isNull);
  });

  test('an arena game is read from its movetext, its opening not twice', () {
    final PastedLine(:line, :game) = read(arena);
    expect(sans(line), ['e4', 'd5', 'exd5', 'Nf3', 'P@e4']);
    expect(
      [for (final m in line.moves) m.clock?.inMilliseconds],
      [null, null, 118100, 118000, 117500],
    );
    expect(game!.name(Seat.a), 'hb-v4');
    expect(game.name(Seat.b), 'hb-v4');
    expect(game.name(Seat.c), 'hm-n1500');
    expect(game.startClock, const Duration(minutes: 2));
    expect(game.heading, 'A + B won · checkmate · Hivemind Arena · Round 3');
    // Its moves were read from the movetext, so the tag stays, and a copy
    // keeps it.
    expect(game.tags['Opening'], '1e2e4 1d7d5');
    expect(
      tableLineText(line, game: game),
      contains('[Opening "1e2e4 1d7d5"]'),
    );
  });

  test('an older arena file plays its Opening tag, then coordinates', () {
    final PastedLine(:line, :game) = read(oldArena);
    expect(sans(line), [
      'e4',
      'd4',
      'd5',
      'e5',
      'exd5',
      'dxe5',
      'Qxd5',
      'P@d2+',
      'Kxd2',
    ]);
    expect(line.moves.last.clock, const Duration(milliseconds: 116400));
    expect(line.moves[4].clock, const Duration(milliseconds: 118100));
    expect(line.moves[0].clock, isNull);
    expect(game!.winner, Team.cd);
    expect(game.ending, 'flag');
    // Its moves are the line's now, so a copy does not play them twice.
    expect(game.tags.containsKey('Opening'), isFalse);
  });

  test('a move that does not play is named, in either arena form', () {
    final broken = arena.replaceFirst('1B. Nf3', '1B. Nf6');
    final refused = readTableLineText(broken) as PastedMovesRefused;
    expect(refused.token, '1B. Nf6');
    expect(refused.game!.name(Seat.a), 'hb-v4');
    expect(refused.start, TablePosition.initial);
    final oldBroken = oldArena.replaceFirst('1a. d8d5', '1a. d8d4');
    expect(
      (readTableLineText(oldBroken) as PastedMovesRefused).token,
      '1a. d8d4',
    );
  });

  test('a file is split into its games at each tag block', () {
    final games = BpgnGames('$fics\r\n$arena\n$oldArena');
    expect(games.length, 3);
    expect(read(games[0]).game!.name(Seat.a), 'larso');
    expect(read(games[1]).game!.tags['Round'], '3');
    expect(read(games[2]).game!.ending, 'flag');
    expect(BpgnGames('1A. e4 1a. e5\n2A. Nf3').length, 1);
    expect(BpgnGames('  \n\n').length, 0);
    expect(BpgnGames('\n\n$arena').length, 1);
  });

  test('a file that opens on a blank line still splits at each tag block', () {
    expect(BpgnGames('\n$arena\n$oldArena').length, 2);
  });

  test('the first game keeps the blank lines before its tags', () {
    expect(BpgnGames('\n$arena')[0], '\n$arena');
  });

  test('a tag\'s escapes are read back to what they stand for', () {
    final game = read(
      r'[Event "a \"b\" c\\d"]'
      '\n\n1A. e4',
    ).game!;
    expect(game.tags['Event'], r'a "b" c\d');
  });

  test('a chat note or a note without words does not say how it ended', () {
    expect(read('[Event "E"]\n\n1A. e4 {C: gg}').game!.ending, isNull);
    expect(read('[Event "E"]\n\n1A. e4 {---}').game!.ending, isNull);
    expect(read('[Event "E"]\n\n1A. e4 {A resigns}').game!.ending, 'A resigns');
  });

  test('movetext keeps its clocks unless told not to', () {
    final line = read(fics).line;
    expect(bpgnMovetext(line), startsWith('1A. e4 {119.000}'));
    expect(bpgnMovetext(line, clocks: false), startsWith('1A. e4 1B. d4'));
  });

  test('a large file is split off the UI isolate the same way', () async {
    final text = '$fics\r\n$arena\n' * 2000;
    expect(text.length, greaterThan(1 << 20));
    final games = await BpgnGames.index(text);
    expect(games.length, 4000);
    expect(games[3999], BpgnGames(text)[3999]);
    expect(read(games[3998]).game!.name(Seat.a), 'larso');
  });

  test('a tag-shaped note in the movetext is not a tag', () {
    final chat = fics.replaceFirst(
      '{GuestXYZ checkmated}',
      '{C: partner [Result "1-0"] lol}\r\n{GuestXYZ checkmated}',
    );
    final PastedLine(:line, :game) = read(chat);
    expect(game!.tags['Result'], '0-1');
    expect(game.winner, Team.cd);
    expect(sans(line), hasLength(7));
    expect(BpgnGames(chat).length, 1);
  });

  test('a game set up from a dual FEN that does not play starts there', () {
    const setup =
        'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR/ b KQkq - 0 1|'
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR/ w KQkq - 0 1';
    final refused =
        readTableLineText(
              '[Event "Set"]\n[SetUpDualFEN "$setup"]\n\n1a. e5 1A. Ke7',
            )
            as PastedMovesRefused;
    expect(refused.token, '1A. Ke7');
    expect(refused.game!.tags['Event'], 'Set');
    expect(refused.start, isNot(TablePosition.initial));
    expect(refused.start.turn(BoardNumber.one).name, 'black');
  });

  test('a game is written back with its tags, clocks and result', () {
    final PastedLine(:line, :game) = read(fics);
    final text = tableLineText(line, game: game);
    expect(text, startsWith('[Event "FICS rated bughouse game"]\n'));
    expect(text, contains('[WhiteAElo "2121"]\n'));
    expect(text, contains('1A. e4 {119.000} 1B. d4 {118.000}'));
    expect(text, endsWith('2b. P@e4 {9.400} {GuestXYZ checkmated} 0-1'));
    for (final row in text.split('\n')) {
      expect(row.length, lessThanOrEqualTo(80));
    }
    final PastedLine(line: again, game: same) = read(text);
    expect(tableLineText(again, game: same), text);
    expect(same!.tags, game!.tags);
  });

  test('a line no longer the game\'s, or an engine line, goes without '
      'the result or the clocks', () {
    final PastedLine(:line, :game) = read(fics);
    final unfinished = tableLineText(line, game: game!.unfinished);
    expect(unfinished, contains('[Result "*"]'));
    expect(unfinished, isNot(contains('checkmated')));
    expect(unfinished, endsWith('2b. P@e4 {9.400} *'));
    final bare = tableLineText(line, clocks: false);
    expect(bare, startsWith('1A. e4 1B. d4 1b. d5'));
    expect(bare, isNot(contains(RegExp('[{}]'))));
  });

  test('a line made here is written as its moves alone', () {
    final line = read('1A. e4 1a. e5').line;
    expect(read('1A. e4 1a. e5').game, isNull);
    expect(tableLineText(line), '1A. e4 1a. e5');
  });

  test('a clock reads as a chess clock shows it', () {
    expect(clockText(const Duration(milliseconds: 118100)), '1:58');
    expect(clockText(const Duration(milliseconds: 9400)), '0:09.4');
    expect(clockText(Duration.zero), '0:00.0');
    expect(clockText(const Duration(minutes: 10)), '10:00');
    expect(
      clockText(const Duration(hours: 1, minutes: 2, seconds: 5)),
      '1:02:05',
    );
    expect(clockComment('119.000'), const Duration(seconds: 119));
    expect(clockComment('1.9s 118.1'), const Duration(milliseconds: 118100));
    expect(
      clockComment('[%clk 1:01:38.6] [%eval 3.19] 45.2s'),
      const Duration(hours: 1, minutes: 1, seconds: 38, milliseconds: 600),
    );
    expect(clockComment('A-black sits @3.0s'), isNull);
    expect(clockComment('a comment'), isNull);
  });
}

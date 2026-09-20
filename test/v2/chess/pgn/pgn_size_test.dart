import 'dart:io';

import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/pgn/pgn_reader.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/pgn_round_trip.dart';

/// Four plies that put the pieces back, so any number of them is a legal
/// game and the position never runs out of moves.
const _shuffle = ['Nf3', 'Nf6', 'Ng1', 'Ng8'];

/// A game of [plies] legal moves on one line.
String longGame(int plies) {
  final buffer = StringBuffer();
  for (var i = 0; i < plies; i++) {
    if (i.isEven) buffer.write('${i ~/ 2 + 1}. ');
    buffer.write('${_shuffle[i % 4]} ');
  }
  return (buffer..write('*')).toString();
}

/// One game whose movetext is a single line of at least [bytes] characters,
/// most of it inside comments, which is the shape that made the old reader
/// quadratic.
String longLine(int bytes) {
  final padding = 'a note that says nothing in particular. ' * 20;
  final buffer = StringBuffer('[Event "One long line"]\n\n');
  for (var i = 0; buffer.length < bytes; i++) {
    if (i.isEven) buffer.write('${i ~/ 2 + 1}. ');
    buffer.write('${_shuffle[i % 4]} {$padding} ');
  }
  return (buffer..write('*')).toString();
}

/// A chapter of [games] games, each a short repertoire line.
String bigChapter(int games) {
  final buffer = StringBuffer('// Big\n// Color: White\n\n');
  for (var i = 0; i < games; i++) {
    buffer.write(
      '[Event "Big: Repertoire for White"]\n'
      '[White "Me"]\n'
      '[Black "Training"]\n'
      '[Result "*"]\n'
      '[LineID "line_$i"]\n'
      '[CumProb "0.${i % 100}"]\n'
      '\n'
      '1. d4 d5 2. c4 e6 {[%eval 0.21] [%clk 0:29:41]} 3. cxd5 exd5 '
      '(3... Nf6 \$6 {Rarely played.} 4. dxe6) 4. Nc3 Nf6 5. Bg5 Be7 *\n\n',
    );
  }
  return buffer.toString();
}

/// Timings go to the console: the numbers are the point of these tests and
/// nobody reads a measurement that only shows up on a failure.
void reportTiming(String line) => stdout.writeln('  $line');

void main() {
  test('a game of two thousand plies reads and writes without the stack', () {
    final game = longGame(2000);
    final clock = Stopwatch()..start();
    final read = readGame(game);
    clock.stop();
    expect(read.issues, isEmpty);
    expect(written(read), game);
    reportTiming('2000 plies: ${clock.elapsedMilliseconds}ms');
    expect(clock.elapsed.inSeconds, lessThan(5));
  });

  test('variations nested three hundred deep do not blow the stack', () {
    // A ply where nobody moved is legal in every position, so the nesting
    // can go as deep as the test likes without running out of moves.
    const depth = 300;
    final game = StringBuffer('1. -- ');
    for (var i = 0; i < depth; i++) {
      game.write('(-- -- ');
    }
    game
      ..write(')' * depth)
      ..write(' *');
    final read = readGame(game.toString());
    expect(read.issues, isEmpty);
    expect(read.tree!.children, hasLength(2));
    expect(() => written(read), returnsNormally);
  });

  test('a megabyte on one line is read in linear time', () {
    final game = longLine(1024 * 1024);
    expect(game.length, greaterThan(1024 * 1024));
    final clock = Stopwatch()..start();
    final read = readGame(game);
    clock.stop();
    expect(read.issues, isEmpty);
    expect(written(read), game);
    reportTiming('1 MB on one line: ${clock.elapsedMilliseconds}ms');
    expect(clock.elapsed.inSeconds, lessThan(5));
  });

  test('a five megabyte chapter is read in one pass', () {
    // About 250 bytes a game, so this is roughly twenty thousand games.
    final text = bigChapter(22000);
    expect(text.length, greaterThan(5 * 1024 * 1024));
    final clock = Stopwatch()..start();
    final chapter = parseChapter(name: 'Big', text: text);
    clock.stop();
    expect(chapter.lines, hasLength(22000));
    expect(chapter.issues, isEmpty);
    expect(writeChapter(chapter), text);
    reportTiming('5 MB chapter: ${clock.elapsedMilliseconds}ms');
    expect(clock.elapsed.inSeconds, lessThan(30));
  });
}

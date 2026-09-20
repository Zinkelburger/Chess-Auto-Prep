import 'package:chess_auto_prep/v2/engines/engine_line.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reads a Stockfish info line', () {
    final line = parseInfoLine(
      'info depth 22 seldepth 31 multipv 2 score cp -35 nodes 1234567 '
      'nps 987654 hashfull 120 tbhits 0 time 1250 pv e7e5 g1f3 b8c6',
    )!;
    expect(line.depth, 22);
    expect(line.multiPv, 2);
    expect(line.score, const Centipawns(-35));
    expect(line.pv, ['e7e5', 'g1f3', 'b8c6']);
  });

  test('a line without multipv is the best line', () {
    final line = parseInfoLine('info depth 3 score mate 2 pv d8h4')!;
    expect(line.multiPv, 1);
    expect(line.score, const MateIn(2));
  });

  test('ignores lines with nothing to show', () {
    expect(
      parseInfoLine('info string NNUE evaluation using nn-abc.nnue'),
      isNull,
    );
    expect(
      parseInfoLine('info depth 20 currmove e2e4 currmovenumber 1'),
      isNull,
    );
    expect(
      parseInfoLine('info depth 20 score cp 30 lowerbound pv e2e4'),
      isNull,
    );
    expect(parseInfoLine('info depth 20 score cp 30 pv'), isNull);
    expect(parseInfoLine('bestmove e2e4 ponder e7e5'), isNull);
  });

  test('scores turn round for White and print like Lichess', () {
    expect(const Centipawns(35).text, '+0.35');
    expect(const Centipawns(-120).text, '-1.20');
    expect(const Centipawns(0).text, '+0.00');
    expect(const MateIn(3).text, '#3');
    expect(const MateIn(-3).text, '#-3');
    expect(
      const Centipawns(35).forWhite(whiteToMove: false),
      const Centipawns(-35),
    );
    expect(const MateIn(3).forWhite(whiteToMove: false), const MateIn(-3));
    expect(const MateIn(3).forWhite(whiteToMove: true), const MateIn(3));
  });

  test('expected score is even at zero and saturates at mate', () {
    expect(const Centipawns(0).expected, 0.5);
    expect(const Centipawns(300).expected, greaterThan(0.7));
    expect(const Centipawns(-300).expected, lessThan(0.3));
    expect(const MateIn(1).expected, 1);
    expect(const MateIn(-1).expected, 0);
  });
}

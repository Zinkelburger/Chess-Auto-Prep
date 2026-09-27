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

  test('a score with no moves after it is still a score', () {
    // What Stockfish says about a board that is already checkmate, before
    // it answers `bestmove (none)`.
    final mate = parseInfoLine('info depth 0 score mate 0')!;
    expect(mate.depth, 0);
    expect(mate.score, const MateIn(0));
    expect(mate.pv, isEmpty);
    // And about a stalemate, which is a draw rather than a mate.
    final stalemate = parseInfoLine('info depth 0 score cp 0')!;
    expect(stalemate.score, const Centipawns(0));
    expect(stalemate.pv, isEmpty);
  });

  test('a mate on the board is a loss for the side to move', () {
    // UCI reports `mate 0` for a position that is already checkmate, so the
    // side the score is about is the side that has been mated.
    const mated = MateIn(0);

    expect(mated.mating, isFalse);
    expect(mated.negated, _mating, reason: 'the other side gave it');
    // A mate that has happened has no distance to print, either way round.
    expect(mated.text, '#');
    expect(mated.negated.text, '#');
    expect(mated.negated, isNot(mated));
    expect(mated.negated.negated, mated);
  });

  test("from White's side, a mate on the board is the mating side's", () {
    // Black to move and mated: White gave the mate.
    expect(const MateIn(0).forWhite(whiteToMove: false), _mating);
    // White to move and mated: White is the side that was mated.
    expect(const MateIn(0).forWhite(whiteToMove: true), isNot(_mating));
  });
}

/// A mate given by the side the score is about.
final _mating = isA<MateIn>().having((mate) => mate.mating, 'mating', isTrue);

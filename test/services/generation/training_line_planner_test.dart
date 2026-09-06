import 'package:flutter_test/flutter_test.dart';
import 'package:dartchess/dartchess.dart';
import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/services/generation/line_extractor.dart';
import 'package:chess_auto_prep/services/generation/training_line_planner.dart';
import 'package:chess_auto_prep/utils/training_markers.dart';
import 'package:chess_auto_prep/services/repertoire_service.dart';

ExtractedLine line(String san, double p, {bool terminal = false}) =>
    ExtractedLine(
      movesSan: san.split(' '),
      movesUci: san.split(' '),
      probability: p,
      leafTerminal: terminal,
    );
TrainingLinePlan plan(
  List<ExtractedLine> lines, {
  int length = 2,
  bool white = true,
  bool rootWhite = true,
}) => TrainingLinePlanner.build(
  lines,
  rootWhiteToMove: rootWhite,
  playAsWhite: white,
  targetOwnMoves: length,
);

void main() {
  test(
    'shared prefixes teach once, all decisions remain available, coverage is monotone',
    () {
      final a = line('e4 e5 Nf3 Nc6 Bb5 a6 Ba4 Nf6', .8);
      final b = line('e4 e5 Nf3 d6 d4 exd4 Nxd4 Nf6', .2);
      final p = plan([a, b]);
      expect(p.exercises.where((e) => e.start == 0), hasLength(1));
      expect(p.totalDecisions, 6);
      expect(p.decisionsAt(p.exercises.length), 6);
      expect(p.coverageAt(p.exercises.length), closeTo(1, 1e-12));
      expect(p.unansweredFrontierMass, 1);
      for (var i = 1; i <= p.exercises.length; i++) {
        expect(p.coverageAt(i), greaterThanOrEqualTo(p.coverageAt(i - 1)));
        for (final e in p.exercises.take(i)) {
          expect(e.start.isEven, isTrue);
          expect(e.end.isEven, isTrue);
        }
      }
      final again = plan([b, a]);
      expect(again.exercises.map((e) => e.key), p.exercises.map((e) => e.key));
      expect(a.movesSan, hasLength(8)); // reference not shortened or mutated
    },
  );
  test(
    'covered opening prefixes become context and both study rankings remain available',
    () {
      final input = [
        line('e4 c5 Nf3', .7),
        line('e4 e5 Nf3 Nc6 Bb5 a6 Ba4 Nf6 O-O Be7 Re1', .3),
      ];
      final efficient = plan(input, length: 6);
      final broad = TrainingLinePlanner.build(
        input,
        rootWhiteToMove: true,
        playAsWhite: true,
        targetOwnMoves: 6,
        reduceRepetition: false,
      );
      expect(efficient.exercises.first.ownMoves, 2);
      expect(broad.exercises.first.ownMoves, 6);
      for (final p in [efficient, broad]) {
        expect(p.exercises[1].start, 2);
        expect(p.practicedMovesAt(2), 7);
        expect(p.decisionsAt(2), 7);
        expect(p.coverageAt(2), closeTo(1, 1e-12));
      }
    },
  );

  test(
    'the actual study loader preserves repeated reference lines as distinct quizzes',
    () {
      for (final white in [true, false]) {
        final p = plan([
          line('e4 e5 Nf3 Nc6 Bb5 a6 Ba4 Nf6 O-O Be7', 1),
        ], white: white);
        final pgn = p.toPgn(
          count: p.exercises.length,
          startFen: kStandardStartFen,
          playAsWhite: white,
          name: 'Exercises',
          searchLabel: 'Pure',
        );
        final loaded = RepertoireService().parseRepertoirePgn(
          pgn,
          colorFromStartingSide: true,
        );
        expect(loaded, hasLength(p.exercises.length));
        for (var i = 0; i < loaded.length; i++) {
          expect(loaded[i].moves, p.exercises[i].line.movesSan);
          expect(loaded[i].puzzleStartIndex, p.exercises[i].start);
          expect(loaded[i].puzzleEndIndex, p.exercises[i].end);
          expect(loaded[i].color, white ? 'white' : 'black');
        }
      }
    },
  );

  test('cut waits for the reply and a quiet pair after a capture sequence', () {
    final p = plan([line('e4 d5 exd5 Qxd5 Nc3 Qd8 d4 Nf6 Nf3 e6', 1)]);
    final first = p.exercises.firstWhere((e) => e.start == 0);
    expect(first.end, 6);
    expect(first.ownMoves, 4);
    expect(first.quietBoundary, isTrue);
    final frontier = plan([line('e4 d5 exd5 Qxd5 Nc3', 1)]).exercises.first;
    expect(frontier.end, 4);
    expect(frontier.quietBoundary, isFalse);
  });
  test('Black and black-to-move FENs place markers on our moves', () {
    final b = plan([line('e4 e5 Nf3 Nc6 Bb5 a6', 1)], white: false);
    expect(b.exercises.every((e) => e.start.isOdd && e.end.isOdd), isTrue);
    final fromBlack = plan(
      [line('e5 Nf3 Nc6 Bb5 a6', 1)],
      white: false,
      rootWhite: false,
    );
    expect(
      fromBlack.exercises.every((e) => e.start.isEven && e.end.isEven),
      isTrue,
    );
  });
  test(
    'terminal replies are not reported as unanswered; empty plans are valid',
    () {
      expect(
        plan([line('f3 e5 g4 Qh4#', 1, terminal: true)]).unansweredFrontierMass,
        0,
      );
      final empty = plan([]);
      expect(empty.exercises, isEmpty);
      expect(empty.coverageAt(0), 0);
      expect(
        empty.toPgn(
          count: 0,
          startFen: kStandardStartFen,
          playAsWhite: true,
          name: 'Empty',
          searchLabel: 'Pure',
        ),
        isEmpty,
      );
    },
  );
  test(
    'PGN keeps context and continuation with exactly one supported start/end marker',
    () {
      final p = plan([line('e4 e5 Nf3 Nc6 Bb5 a6 Ba4 Nf6', 1)]);
      final text = p.toPgn(
        count: p.exercises.length,
        startFen: kStandardStartFen,
        playAsWhite: true,
        name: 'Study',
        searchLabel: 'Fast (4-ply, approximate)',
      );
      final games = PgnGame.parseMultiGamePgn(text).toList();
      expect(games, hasLength(p.exercises.length));
      for (var i = 0; i < games.length; i++) {
        final data = games[i].moves.mainline().toList();
        expect(data.map((m) => m.san), p.exercises[i].line.movesSan);
        final starts = <int>[], ends = <int>[];
        for (var j = 0; j < data.length; j++) {
          final comment = data[j].comments?.join(' ');
          if (hasPuzzleStart(comment)) starts.add(j);
          if (hasPuzzleEnd(comment)) ends.add(j);
        }
        expect(starts, [p.exercises[i].start]);
        expect(ends, [p.exercises[i].end]);
      }
    },
  );
}

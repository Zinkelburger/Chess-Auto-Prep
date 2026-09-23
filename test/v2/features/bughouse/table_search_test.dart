import 'package:chess_auto_prep/v2/chess/bughouse/hivemind.dart';
import 'package:chess_auto_prep/v2/chess/bughouse/table.dart';
import 'package:chess_auto_prep/v2/engines/hivemind_engine.dart';
import 'package:chess_auto_prep/v2/features/bughouse/bughouse_lab.dart';
import 'package:chess_auto_prep/v2/features/bughouse/table_search.dart';
import 'package:chess_auto_prep/v2/storage/bughouse_books.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_bughouse.dart';

/// The book's answer for the start: e4 and d4 on board 1 scored for
/// `even` and `ahead`, A + B's side.
HivemindFound startInBook() => const HivemindFound({
  (BoardNumber.one, 'e2e4'): {
    ClockCase.even: (score: TableScore(score: 0.20), pv: 'A e4 · C e5'),
    ClockCase.abMaySit: (score: TableScore(score: 2.40), pv: 'A e4 · sit'),
  },
  (BoardNumber.one, 'd2d4'): {
    ClockCase.even: (score: TableScore(score: 0.30), pv: 'A d4 · C d5'),
  },
});

void main() {
  late BughouseLab lab;
  late ScriptedBughouse outside;
  late TableSearch search;

  setUp(() {
    lab = BughouseLab();
    outside = ScriptedBughouse();
    search = TableSearch(
      lab: lab,
      book: outside.book,
      startEngine: () => outside.outside.launch(cores: 2),
      depth: (ownNodes: 50, childNodes: 20, topMoves: 2),
    );
  });

  tearDown(() {
    search.dispose();
    lab.dispose();
  });

  test(
    'a position in the book is scored at once, and nothing is searched',
    () async {
      outside.book.positions[TablePosition.initial.bookKey] = startInBook();
      search.open();
      await pumpEventQueue();
      expect(search.scores, isA<ScoresFromBook>());
      final rows = tableRows(
        lab.position,
        BoardNumber.one,
        search.scores.scores,
      );
      // Board 1 is A's (A + B), so the book's numbers read as they are.
      expect(rows.first.move.san, 'd4');
      expect(rows.first.score.text, '+0.30');
      expect(rows[1].move.san, 'e4');
      expect(rows[2].score.text, '—');
      expect(outside.starts, 0);
    },
  );

  test('the Time chip reads the book’s other clock without a search', () async {
    outside.book.positions[TablePosition.initial.bookKey] = startInBook();
    search.open();
    await pumpEventQueue();
    lab.setClock(ClockCase.abMaySit);
    await pumpEventQueue();
    final rows = tableRows(lab.position, BoardNumber.one, search.scores.scores);
    expect(rows.first.score.text, '+2.40');
    expect(outside.starts, 0);
  });

  test('a position the book lacks is scored by the engine', () async {
    search.open();
    await pumpEventQueue();
    final scores = search.scores as ScoresSearched;
    expect(scores.finished, isTrue);
    // Both teams searched for the zero, then two moves a board answered.
    final asked = outside.engine.asked;
    expect(asked.take(2).map((q) => q.team), [Team.ab, Team.cd]);
    expect(asked.first.budget, isA<NodeBudget>());
    expect(asked.length, 2 + 4);
    expect(scores.scores.length, 4);
    // The table is read from the mover's side: C + D moves on board 2.
    final two = tableRows(lab.position, BoardNumber.two, scores.scores);
    expect(two.first.score.isEmpty, isFalse);
    expect(two.first.pv, startsWith('D '));
  });

  test('a clock the book lacks is searched, not shown empty', () async {
    outside.book.positions[TablePosition.initial.bookKey] = startInBook();
    lab.setClock(ClockCase.cdMaySit);
    search.open();
    await pumpEventQueue();
    expect(search.scores, isA<ScoresSearched>());
    expect(outside.engine.asked.first.maySit, isFalse);
    expect(outside.engine.asked[1].maySit, isTrue);
  });

  test('a search made before is remembered', () async {
    search.open();
    await pumpEventQueue();
    final asked = outside.engine.asked.length;
    lab.play(BoardNumber.one, 'e2e4');
    await pumpEventQueue();
    lab.go(BoardNumber.one, 0);
    await pumpEventQueue();
    final before = outside.engine.asked.length;
    expect(before, greaterThan(asked));
    lab.play(BoardNumber.one, 'e2e4');
    await pumpEventQueue();
    expect(outside.engine.asked.length, before);
  });

  test('a new position makes the search on the old one stale', () async {
    outside.engine.hold = true;
    search.open();
    await pumpEventQueue();
    lab.play(BoardNumber.one, 'e2e4');
    await pumpEventQueue();
    // The move cut the old search short; its answer is not the new table's.
    expect(outside.engine.stops, greaterThan(0));
    outside.engine.hold = false;
    outside.engine.release();
    await pumpEventQueue();
    final scores = search.scores as ScoresSearched;
    for (final key in scores.scores.keys) {
      expect(
        lab.position.legalMoves(key.$1).map((m) => m.uci),
        contains(key.$2),
      );
    }
    expect(scores.finished, isTrue);
  });

  test(
    'an engine that will not start says so, until Analyze asks again',
    () async {
      outside.startFailure = 'This build has no bughouse engine.';
      search.open();
      await pumpEventQueue();
      expect(
        (search.scores as ScoresFailed).reason,
        'This build has no bughouse engine.',
      );
      lab.play(BoardNumber.one, 'e2e4');
      await pumpEventQueue();
      expect(outside.starts, 1);
      outside.startFailure = null;
      await search.analyze();
      expect(outside.starts, 2);
      expect(search.analysis, isA<AnalysisNoMove>());
    },
  );

  test('an engine that dies mid-search fails the tables in words', () async {
    outside.engine.hold = true;
    search.open();
    await pumpEventQueue();
    outside.engine.crash();
    await pumpEventQueue();
    expect(
      (search.scores as ScoresFailed).reason,
      'Analysis failed: The bughouse engine stopped.',
    );
  });

  group('Analyze', () {
    test('searches our team, then theirs for the zero', () async {
      await (search..open()).analyze();
      final done = search.analysis as AnalysisDone;
      expect(done.team, Team.ab);
      expect(done.zero, ZeroSource.measured);
      expect(done.rows.length, 3);
      final ours = outside.engine.asked.firstWhere(
        (q) => q.budget is TimeBudget,
      );
      expect(ours.lines, 3);
      expect((ours.budget as TimeBudget).time, const Duration(seconds: 3));
      // A + B's cp −200 against C + D's −200 is level.
      expect(done.advantage.forTeam(Team.ab).text, '0.00');
    });

    test(
      'asks with the chips: the clock, the board to move on, the time',
      () async {
        lab
          ..setClock(ClockCase.abMaySit)
          ..setMustMove(MustMove.one)
          ..setBudget(const Duration(seconds: 10));
        await (search..open()).analyze();
        final ours = outside.engine.asked.firstWhere(
          (q) => q.budget is TimeBudget,
        );
        expect(ours.maySit, isTrue);
        expect(ours.mustMove, MustMove.one);
        expect((ours.budget as TimeBudget).time, const Duration(seconds: 10));
        final theirs = outside.engine.asked.lastWhere(
          (q) => q.budget is TimeBudget,
        );
        expect(theirs.team, Team.cd);
        expect(theirs.maySit, isFalse);
        expect(theirs.mustMove, MustMove.either);
      },
    );

    test(
      'stopped early, keeps what it found against the assumed zero',
      () async {
        search.open();
        await pumpEventQueue();
        outside.engine.hold = true;
        final analysing = search.analyze();
        await pumpEventQueue();
        expect(search.analysis, isA<AnalysisRunning>());
        search.stopAnalysis();
        await analysing;
        final done = search.analysis as AnalysisDone;
        expect(done.zero, ZeroSource.assumed);
        expect(
          outside.engine.asked.where((q) => q.budget is TimeBudget).length,
          1,
        );
      },
    );

    test('a new position throws the answer away', () async {
      search.open();
      await pumpEventQueue();
      outside.engine.hold = true;
      final analysing = search.analyze();
      await pumpEventQueue();
      lab.play(BoardNumber.one, 'e2e4');
      outside.engine.hold = false;
      outside.engine.release();
      await analysing;
      expect(search.analysis, isA<AnalysisIdle>());
    });
  });

  test('leaving the mode stops the engine’s work', () async {
    outside.engine.hold = true;
    search.open();
    await pumpEventQueue();
    final stops = outside.engine.stops;
    search.close();
    expect(outside.engine.stops, stops + 1);
  });
}

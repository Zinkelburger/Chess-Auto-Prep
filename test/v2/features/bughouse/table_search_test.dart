import 'dart:async';

import 'package:chess_auto_prep/v2/chess/bughouse/hivemind.dart';
import 'package:chess_auto_prep/v2/chess/bughouse/table.dart';
import 'package:chess_auto_prep/v2/engines/hivemind_engine.dart';
import 'package:chess_auto_prep/v2/features/bughouse/bughouse_lab.dart';
import 'package:chess_auto_prep/v2/features/bughouse/table_search.dart';
import 'package:chess_auto_prep/v2/storage/bughouse_books.dart';
import 'package:chess_auto_prep/v2/storage/pending_writes.dart';
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
      depth: (ownNodes: 50, childNodes: 20),
      passes: const [Duration(seconds: 1), Duration(seconds: 2)],
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

  List<HivemindQuestion> nodeSearches() => [
    for (final q in outside.engine.asked)
      if (q.budget is NodeBudget) q,
  ];

  test(
    'with the engine off nothing is searched; the table is unscored',
    () async {
      search.open();
      await pumpEventQueue();
      expect(search.scores, isA<ScoresNone>());
      expect(outside.starts, 0);
    },
  );

  test('the engine scores every move of a position the book lacks, and '
      'adds it to the book', () async {
    search
      ..open()
      ..toggleEngine();
    await pumpEventQueue();
    final scores = search.scores as ScoresSearched;
    expect(scores.finished, isTrue);
    // Both teams searched for the zero, then every move of both boards.
    final searches = nodeSearches();
    expect(searches.take(2).map((q) => q.team), [Team.ab, Team.cd]);
    expect(searches.length, 2 + 40);
    expect(scores.scores.length, 40);
    // The table is read from the mover's side: C + D moves on board 2.
    final two = tableRows(lab.position, BoardNumber.two, scores.scores);
    expect(two.first.score.isEmpty, isFalse);
    expect(two.first.pv, startsWith('D '));
    final saved = outside.book.saved.single;
    expect(saved.position, TablePosition.initial);
    expect(saved.clock, ClockCase.even);
    expect(saved.moves.length, 40);
    expect(saved.picks.keys, {Team.ab, Team.cd});
    expect(saved.line, '');
    expect(saved.provenance['engine_name'], 'Scripted Hivemind');
    expect(saved.provenance['reported_searches'], hasLength(42));
    expect(saved.provenance['require_move_on'], 'none');
  });

  test('a position in the book for the clock is not scored again', () async {
    outside.book.positions[TablePosition.initial.bookKey] = startInBook();
    search
      ..open()
      ..toggleEngine();
    await pumpEventQueue();
    expect(search.scores, isA<ScoresFromBook>());
    expect(nodeSearches(), isEmpty);
    expect(outside.book.saved, isEmpty);
  });

  test('a clock the book lacks is scored with its team’s bit', () async {
    outside.book.positions[TablePosition.initial.bookKey] = startInBook();
    lab.setClock(ClockCase.cdMaySit);
    search
      ..open()
      ..toggleEngine();
    await pumpEventQueue();
    expect(search.scores, isA<ScoresSearched>());
    expect(nodeSearches().first.maySit, isFalse);
    expect(nodeSearches()[1].maySit, isTrue);
    expect(outside.book.saved.single.clock, ClockCase.cdMaySit);
  });

  test('the line that reached a position is stored with it', () async {
    search.open();
    lab.play(BoardNumber.one, 'e2e4');
    search.toggleEngine();
    await pumpEventQueue();
    expect(outside.book.saved.single.line, 'A:e4');
    expect(outside.book.saved.single.ply, 1);
  });

  test('a search made before is remembered', () async {
    search
      ..open()
      ..toggleEngine();
    await pumpEventQueue();
    lab.play(BoardNumber.one, 'e2e4');
    await pumpEventQueue();
    lab.go(BoardNumber.one, 0);
    await pumpEventQueue();
    final before = nodeSearches().length;
    lab.play(BoardNumber.one, 'e2e4');
    await pumpEventQueue();
    expect(nodeSearches().length, before);
  });

  test('a new position makes the search on the old one stale', () async {
    outside.engine.hold = true;
    search
      ..open()
      ..toggleEngine();
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
    expect(outside.book.saved.single.position, lab.position);
  });

  test('an engine that will not start turns the switch off in words, and '
      'is tried again when switched on', () async {
    outside.startFailure = 'This build has no bughouse engine.';
    search
      ..open()
      ..toggleEngine();
    await pumpEventQueue();
    expect(search.engineOn, isFalse);
    final trouble = (search.lines as LinesStopped).trouble;
    expect(trouble, isA<EngineNotStarted>());
    expect(trouble.reason, 'This build has no bughouse engine.');
    outside.startFailure = null;
    search.toggleEngine();
    await pumpEventQueue();
    expect(outside.starts, 2);
    expect((search.scores as ScoresSearched).finished, isTrue);
  });

  test('an engine that dies mid-search stops in words', () async {
    outside.engine.hold = true;
    search
      ..open()
      ..toggleEngine();
    await pumpEventQueue();
    outside.engine.crash();
    await pumpEventQueue();
    final trouble = (search.lines as LinesStopped).trouble;
    expect(trouble, isA<SearchFailed>());
    expect(trouble.reason, 'The bughouse engine stopped.');
  });

  test(
    'retry finishes a partial table without searching scored moves again',
    () async {
      var children = 0;
      outside.engine.answer = (question) {
        if (question.budget case NodeBudget(nodes: 20)) {
          children++;
          if (children == 4) return const HivemindFailed('interrupted');
        }
        return firstMoves(question);
      };
      search
        ..open()
        ..toggleEngine();
      await pumpEventQueue();
      expect((search.scores as ScoresSearched).done, 3);
      expect(outside.book.saved, isEmpty);
      expect(search.engineOn, isFalse);
      search.toggleEngine();
      await pumpEventQueue();
      expect((search.scores as ScoresSearched).finished, isTrue);
      expect(children, 41); // Forty moves and the one failed attempt.
      expect(outside.book.saved.single.moves, hasLength(40));
      expect(outside.starts, 2);
    },
  );

  test(
    'a failed save retains complete analysis and retries only the write',
    () async {
      final pending = PendingWrites();
      search.dispose();
      search = TableSearch(
        lab: lab,
        book: outside.book,
        startEngine: () => outside.outside.launch(cores: 2),
        pendingWrites: pending,
        passes: const [Duration(seconds: 1)],
      );
      final write = Completer<HivemindSave>();
      final attempted = <HivemindEntry>[];
      outside.book.saving = (entry) {
        attempted.add(entry);
        return write.future;
      };
      search
        ..open()
        ..toggleEngine();
      await pumpEventQueue();
      expect((search.scores as ScoresSearched).finished, isTrue);
      expect(search.analysisSave, isA<AnalysisSaving>());
      write.complete(const HivemindSaveFailed('disk full'));
      await pumpEventQueue();
      expect((search.analysisSave as AnalysisSaveFailed).detail, 'disk full');
      expect(await pending.settle(), contains('disk full'));
      final questions = outside.engine.asked.length;
      outside.book.saving = null;
      await search.retrySave();
      expect(search.analysisSave, isA<AnalysisSaved>());
      expect(await pending.settle(), isNull);
      expect(outside.engine.asked.length, questions);
      expect(outside.book.saved.single, attempted.single);
    },
  );

  test(
    'discard frees earlier failures absent from the current table',
    () async {
      final earlier = search.pendingWrites.accept<HivemindSave>(
        resource: outside.book,
        label: 'Earlier analysis',
        work: () async => const HivemindSaveFailed('history changed'),
        problem: (outcome) =>
            outcome is HivemindSaveFailed ? outcome.detail : null,
      );
      await earlier.run();
      search
        ..open()
        ..toggleEngine();
      await pumpEventQueue();
      expect(search.analysisSave, isA<AnalysisSaveFailed>());
      expect(search.pendingWrites.unfinished(outside.book), hasLength(2));
      await search.discardFailedSaves();
      expect(await search.pendingWrites.settle(), isNull);
      expect(search.analysisSave, isA<AnalysisSaveDiscarded>());
      outside.book.saving = null;
      lab.play(BoardNumber.one, 'e2e4');
      await pumpEventQueue();
      expect(search.analysisSave, isA<AnalysisSaved>());
    },
  );

  test(
    'accepted analysis save remains retryable after owner disposal',
    () async {
      final pending = PendingWrites();
      search.dispose();
      search = TableSearch(
        lab: lab,
        book: outside.book,
        startEngine: () => outside.outside.launch(cores: 2),
        pendingWrites: pending,
        passes: const [Duration(seconds: 1)],
      );
      outside.book.saving = (_) async => const HivemindSaveFailed('disk full');
      search
        ..open()
        ..toggleEngine();
      await pumpEventQueue();
      expect(search.analysisSave, isA<AnalysisSaveFailed>());
      search.dispose();
      search = TableSearch(
        lab: lab,
        book: outside.book,
        startEngine: () => outside.outside.launch(cores: 2),
      );
      outside.book.saving = null;
      await pending.retry(outside.book);
      expect(await pending.settle(), isNull);
      expect(outside.book.saved, hasLength(1));
    },
  );

  test(
    'save outcome belongs to the captured position after navigation',
    () async {
      final write = Completer<HivemindSave>();
      outside.book.saving = (_) => write.future;
      search
        ..open()
        ..toggleEngine();
      await pumpEventQueue();
      expect(search.analysisSave, isA<AnalysisSaving>());
      search.toggleEngine();
      lab.play(BoardNumber.one, 'e2e4');
      await pumpEventQueue();
      write.complete(const HivemindSaveFailed('disk full'));
      await pumpEventQueue();
      expect(search.analysisSave, isNull);
      lab.go(BoardNumber.one, 0);
      await pumpEventQueue();
      expect(search.analysisSave, isA<AnalysisSaveFailed>());
      expect((search.scores as ScoresSearched).finished, isTrue);
      outside.book.saving = null;
      await search.retrySave();
      expect(outside.book.saved.single.position, TablePosition.initial);
    },
  );

  group('The engine switch', () {
    List<HivemindQuestion> passes() => [
      for (final q in outside.engine.asked)
        if (q.budget is TimeBudget) q,
    ];

    test('searches both teams in passes that think longer each time', () async {
      outside.book.positions[TablePosition.initial.bookKey] = startInBook();
      search
        ..open()
        ..toggleEngine();
      await pumpEventQueue();
      final on = search.lines as LinesOn;
      expect(on.thinking, isNull);
      expect(on.zero, ZeroSource.measured);
      expect(on.lines.keys, {Team.ab, Team.cd});
      expect(on.lines[Team.ab]!.rows.length, 3);
      // A + B's cp −200 against C + D's −200 is level.
      expect(on.lines[Team.ab]!.advantage.text, '0.00');
      expect(passes().map((q) => (q.budget as TimeBudget).time), [
        const Duration(seconds: 1),
        const Duration(seconds: 1),
        const Duration(seconds: 2),
        const Duration(seconds: 2),
      ]);
      expect(passes().map((q) => q.team), [Team.ab, Team.cd, Team.ab, Team.cd]);
      expect(passes().every((q) => q.lines == 3), isTrue);
    });

    test('scores the table between its first and second pass', () async {
      search
        ..toggleEngine()
        ..open();
      await pumpEventQueue();
      final kinds = [
        for (final q in outside.engine.asked) q.budget is TimeBudget,
      ];
      expect(kinds.take(2), [true, true]);
      expect(kinds.skip(2).take(42).every((pass) => !pass), isTrue);
      expect(kinds.skip(44), [true, true]);
    });

    test('asks with the clock chip', () async {
      lab.setClock(ClockCase.abMaySit);
      search
        ..open()
        ..toggleEngine();
      await pumpEventQueue();
      expect(passes().first.maySit, isTrue);
      expect(passes()[1].maySit, isFalse);
      expect(passes().every((q) => q.mustMove == MustMove.either), isTrue);
    });

    test('off, the pass under way is cut short and its lines go', () async {
      search.open();
      await pumpEventQueue();
      outside.engine.hold = true;
      search.toggleEngine();
      await pumpEventQueue();
      expect(search.lines, isA<LinesOn>());
      final stops = outside.engine.stops;
      search.toggleEngine();
      expect(outside.engine.stops, greaterThan(stops));
      await pumpEventQueue();
      expect(search.lines, isA<LinesOff>());
      expect(passes().length, 1);
    });

    test('a new position starts the passes again from there', () async {
      search.open();
      await pumpEventQueue();
      outside.engine.hold = true;
      search.toggleEngine();
      await pumpEventQueue();
      lab.play(BoardNumber.one, 'e2e4');
      outside.engine.hold = false;
      outside.engine.release();
      await pumpEventQueue();
      final on = search.lines as LinesOn;
      expect(on.position, lab.position);
      expect(on.thinking, isNull);
    });

    test('an engine that fails turns the switch off in words', () async {
      search.open();
      await pumpEventQueue();
      outside.engine.answer = (_) => const HivemindFailed('it broke');
      search.toggleEngine();
      await pumpEventQueue();
      expect(search.engineOn, isFalse);
      final stopped = search.lines as LinesStopped;
      expect(stopped.trouble.reason, 'it broke');
    });
  });

  test('leaving the mode quits the engine; coming back starts one', () async {
    outside.engine.hold = true;
    search
      ..toggleEngine()
      ..open();
    await pumpEventQueue();
    search.close();
    await outside.engine.exited;
    expect(outside.starts, 1);
    search.open();
    await pumpEventQueue();
    // The scripted engine has gone, so the next start hands back a dead
    // one; what matters is that another was asked for.
    expect(outside.starts, 2);
  });

  test(
    'an engine that finishes starting after the lab is gone is quit',
    () async {
      final starting = Completer<HivemindStart>();
      final late =
          TableSearch(
              lab: lab,
              book: outside.book,
              startEngine: () => starting.future,
            )
            ..toggleEngine()
            ..open();
      await pumpEventQueue();
      late.dispose();
      final engine = ScriptedHivemind();
      starting.complete(HivemindStarted(engine));
      await pumpEventQueue();
      expect(engine.gone, isTrue);
    },
  );
}

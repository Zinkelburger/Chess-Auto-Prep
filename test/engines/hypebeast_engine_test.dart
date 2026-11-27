import 'dart:async';

import 'package:chess_auto_prep/chess/bughouse/hypebeast.dart';
import 'package:chess_auto_prep/chess/bughouse/table.dart';
import 'package:chess_auto_prep/engines/engine.dart';
import 'package:chess_auto_prep/engines/hypebeast_engine.dart';
import 'package:chess_auto_prep/engines/uci_process.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

const _net = '/engines/bughouse-cd8cceab93fe.nnue';

/// A HypeBeast that answers the way the real one does: `uciok`, `readyok`,
/// the line naming its net at the start of a search, then the lines the
/// test gives each `go` and their `bestmove`.
final class AnsweringProcess implements UciProcess {
  AnsweringProcess({this.silent = false, this.net = NetSays.loaded});

  /// Says nothing at all, as a binary that never reaches `main`.
  final bool silent;

  /// What the engine says of its net at its first search.
  final NetSays net;
  final sent = <String>[];
  final _out = StreamController<String>();
  bool killed = false;
  bool _checked = false;

  /// What the next `go` prints; left unset, the search never ends.
  List<String>? next;

  /// While set, `isready` waits for [ready].
  bool holdReady = false;
  int _readyOwed = 0;

  /// Answers every `isready` held.
  void ready() {
    for (; _readyOwed > 0; _readyOwed--) {
      say('readyok');
    }
  }

  @override
  int get pid => 4343;

  @override
  Stream<String> get lines => _out.stream;

  @override
  void send(String line) {
    sent.add(line);
    if (silent || _out.isClosed) return;
    if (line == 'uci') {
      say('id name Fairy-Stockfish 171126');
      say('option name Seat type combo default Awhite var Awhite var Ablack');
      say('uciok');
    } else if (line == 'isready') {
      if (holdReady) {
        _readyOwed++;
      } else {
        say('readyok');
      }
    } else if (line.startsWith('go') && !_checked) {
      _checked = true;
      switch (net) {
        case NetSays.loaded:
          say('info string NNUE evaluation using $_net enabled');
          say('info depth 1 seldepth 1 multipv 1 score cp 92 nodes 20 pv d2d4');
          say('bestmove (d2d4,pass)');
        case NetSays.classical:
          say('info string classical evaluation enabled');
          say('bestmove (e2e3,pass)');
        case NetSays.unreadable:
          say(
            'info string ERROR: The option is set to true, but the network '
            'file $_net was not loaded successfully.',
          );
          say('info string ERROR: The engine will be terminated now.');
          scheduleMicrotask(() => scheduleMicrotask(crash));
      }
    } else if (line.startsWith('go')) {
      final printed = next;
      next = null;
      printed?.forEach(say);
    } else if (line == 'quit') {
      crash();
    }
  }

  @override
  Future<void> kill() async {
    killed = true;
    crash();
  }

  void say(String line) => scheduleMicrotask(() {
    if (!_out.isClosed) _out.add(line);
  });

  void crash() {
    if (!_out.isClosed) unawaited(_out.close());
  }

  /// What was sent after the handshake and the net's proof.
  List<String> get asked =>
      sent.skipWhile((l) => l != 'go nodes 1').skip(1).toList();
}

enum NetSays { loaded, classical, unreadable }

/// Lines of a real v1.1.1 search of board 1 for Black, coordinated.
const coordinatedSearch = [
  'info string hb_forecast {"ready":true,"lines":[]}',
  'info depth 16 seldepth 19 multipv 1 score cp 246 nodes 392655 nps 666646 '
      'tbhits 0 time 589 pv e7e6 d5e6 c8e6 g1f3',
  'info depth 17 seldepth 18 multipv 1 score cp 263 nodes 576763 nps 669098 '
      'tbhits 0 time 862 pv e7e6 b1c3 e6d5 d2d4 g8f6',
  'info string hb_coord {"reason":"kept_main","candidates":['
      '{"move":"e7e6","L":262,"S":176},{"move":"c7c6","L":146,"S":98}]}',
  'info depth 17 score cp 263 nodes 1126201 time 1960',
  'info string hb_summary decision=e7e6 main_depth=17 total_nodes=1126201',
  'bestmove (e7e6,pass)',
];

/// A search of board 1 alone with three lines.
const aloneSearch = [
  'info depth 1 seldepth 1 multipv 1 score cp 92 nodes 21 pv d2d4',
  'info depth 1 seldepth 1 multipv 2 score cp 20 nodes 21 pv e2e3',
  'info depth 1 seldepth 1 multipv 3 score cp 2 nodes 21 pv d2d3',
  'info depth 2 seldepth 2 multipv 1 score cp 134 nodes 92 pv e2e4 a7a6',
  'info depth 2 seldepth 2 multipv 2 score cp 130 nodes 92 pv d2d4 a7a6',
  'info depth 2 seldepth 2 multipv 3 score cp 25 nodes 92 pv e2e3 e7e5',
  'bestmove (e2e4,pass)',
];

final _afterE4 = TablePosition.initial.play(BoardNumber.one, 'e2e4')!.after;

HypeBeastQuestion question({
  TablePosition? position,
  BoardNumber board = BoardNumber.one,
  int lines = 3,
  bool coordination = false,
  int threads = 4,
  HypeBeastBudget budget = const NodeBudget(2000),
  ({TablePosition root, List<String> moves})? played,
  TableClocks? clocks,
}) => (
  position: position ?? TablePosition.initial,
  played: played,
  board: board,
  lines: lines,
  coordination: coordination,
  clocks: clocks,
  threads: threads,
  budget: budget,
);

void main() {
  Future<(HypeBeastProcess, AnsweringProcess)> started() async {
    final process = AnsweringProcess();
    final engine = await HypeBeastProcess.start(
      process,
      net: _net,
      options: {'Hash': '128'},
    );
    return (engine!, process);
  }

  HypeBeastProcess startFake(FakeAsync time, AnsweringProcess process) {
    late HypeBeastProcess engine;
    unawaited(
      HypeBeastProcess.start(process, net: _net).then((e) => engine = e!),
    );
    time.flushMicrotasks();
    return engine;
  }

  test('the handshake turns HypeBeast on, loads the net and proves it with '
      'one node', () async {
    final (engine, process) = await started();
    expect(engine.provenance['engine_name'], 'Fairy-Stockfish 171126');
    expect(engine.provenance['options'], {'Hash': '128'});
    expect(engine.provenance['net'], _net);
    expect(process.sent, [
      'uci',
      'setoption name HypeBeast value true',
      'setoption name EvalFile value $_net',
      'setoption name Hash value 128',
      'isready',
      'setoption name Coordination value false',
      'position startpos',
      'go nodes 1',
    ]);
  });

  test('a net the engine cannot read fails the start in words', () async {
    final process = AnsweringProcess(net: NetSays.unreadable);
    await expectLater(
      HypeBeastProcess.start(process, net: _net),
      throwsA(
        isA<EngineFailure>().having(
          (f) => f.message,
          'message',
          'its net did not load.',
        ),
      ),
    );
    expect(process.killed, isTrue);
  });

  test('a net taken for another variant\'s, so classical evaluation, fails '
      'the start', () async {
    final process = AnsweringProcess(net: NetSays.classical);
    await expectLater(
      HypeBeastProcess.start(process, net: _net),
      throwsA(
        isA<EngineFailure>().having(
          (f) => f.message,
          'message',
          contains('not taken for a bughouse net'),
        ),
      ),
    );
    expect(process.killed, isTrue);
  });

  test('a search tells the engine the seat, the team, the lines and the '
      'threads, then the table', () async {
    final (engine, process) = await started();
    process.next = coordinatedSearch;
    await engine.search(
      question(position: _afterE4, coordination: true, threads: 3),
    );
    expect(process.asked, [
      'setoption name Threads value 3',
      'setoption name Seat value Ablack',
      'setoption name Team value black',
      'setoption name Coordination value true',
      'setoption name MultiPV value 1',
      'isready',
      'position fen ${_afterE4.dualFen}',
      'go nodes 2000',
    ]);
  });

  test('with clocks: a new game first, then the four clocks and whether the '
      'seat\'s team is ahead, before the table', () async {
    final (engine, process) = await started();
    expect(engine.clocked, isFalse);
    process.next = coordinatedSearch;
    const clocks = TableClocks(
      a: Duration(milliseconds: 78226),
      c: Duration(milliseconds: 73129),
      d: Duration(milliseconds: 73259),
      b: Duration(milliseconds: 78096),
    );
    // C, Black on board 1, is on move: C + D is ahead when C has more time
    // than B, which it has not.
    await engine.search(
      question(position: _afterE4, coordination: true, clocks: clocks),
    );
    expect(engine.clocked, isTrue);
    final asked = process.asked;
    expect(asked.first, 'ucinewgame');
    expect(
      asked,
      contains('setoption name Clocks value 78226,73129,73259,78096'),
    );
    expect(asked, contains('setoption name TimeAdvantage value false'));
    expect(
      asked.indexOf('isready'),
      greaterThan(asked.indexOf('setoption name TimeAdvantage value false')),
    );
    expect(asked.last, 'go nodes 2000');

    // A, on move at the start, is ahead of D: A + B has the time advantage.
    process.sent.clear();
    process.next = coordinatedSearch;
    await engine.search(question(coordination: true, clocks: clocks));
    expect(process.sent.first, 'ucinewgame');
    expect(process.sent, contains('setoption name TimeAdvantage value true'));
    // The same clocks are not sent again.
    expect(process.sent.where((l) => l.contains('name Clocks')), isEmpty);

    // A search without clocks sends none, but the engine still holds them.
    process.sent.clear();
    process.next = coordinatedSearch;
    await engine.search(question(coordination: true));
    expect(process.sent, isNot(contains('ucinewgame')));
    expect(engine.clocked, isTrue);
  });

  test('alone, the board gets every line asked', () async {
    final (engine, process) = await started();
    process.next = aloneSearch;
    final answer = await engine.search(question()) as HypeBeastSearched;
    expect(process.asked, contains('setoption name MultiPV value 3'));
    expect(
      process.asked,
      isNot(contains('setoption name Coordination value true')),
    );
    expect(answer.decision, const SeatDecision('e2e4'));
    expect(answer.report.lines.map((l) => (l.multipv, l.cp)), [
      (1, 134),
      (2, 130),
      (3, 25),
    ]);
  });

  test('board 2 is searched for its side to move', () async {
    final (engine, process) = await started();
    process.next = ['bestmove (pass,d7d5)'];
    final table = TablePosition.initial.play(BoardNumber.two, 'd2d4')!.after;
    final answer =
        await engine.search(question(position: table, board: BoardNumber.two))
            as HypeBeastSearched;
    expect(process.asked, contains('setoption name Seat value Bblack'));
    expect(process.asked, contains('setoption name Team value white'));
    expect(answer.decision, const SeatDecision('d7d5'));
  });

  test('a search reports as it goes and answers with the decision and the '
      'coordinator\'s report', () async {
    final (engine, process) = await started();
    process.next = coordinatedSearch;
    final reports = <SeatReport>[];
    final answer =
        await engine.search(
              question(position: _afterE4, coordination: true),
              onReport: reports.add,
            )
            as HypeBeastSearched;
    expect(reports.map((r) => r.main?.depth), [16, 17, 17, 17, 17]);
    expect(reports.last.nodes, 1126201);
    expect(answer.decision, const SeatDecision('e7e6'));
    expect(answer.report.coordination!.candidates.map((c) => c.move), [
      'e7e6',
      'c7c6',
    ]);
  });

  test('options that have not changed are not sent again', () async {
    final (engine, process) = await started();
    process.next = aloneSearch;
    await engine.search(question());
    process.sent.clear();
    process.next = aloneSearch;
    await engine.search(
      question(budget: const TimeBudget(Duration(seconds: 3))),
    );
    expect(process.sent.where((l) => l.startsWith('setoption')), isEmpty);
    expect(process.sent, contains('go movetime 3000'));
  });

  test('a search told the game sends its moves, so a repeated position is '
      'seen as one', () async {
    final (engine, process) = await started();
    process.next = aloneSearch;
    await engine.search(
      question(
        played: (
          root: TablePosition.initial,
          moves: const ['1g1f3', '1b8c6', '1f3g1', '1c6b8'],
        ),
      ),
    );
    expect(
      process.sent,
      contains(
        'position fen ${TablePosition.initial.dualFen} '
        'moves 1g1f3 1b8c6 1f3g1 1c6b8',
      ),
    );
  });

  test('a seat with no move gets no decision', () async {
    final (engine, process) = await started();
    process.next = ['info depth 0 score mate 0', 'bestmove (none)'];
    final answer = await engine.search(question()) as HypeBeastSearched;
    expect(answer.decision, isNull);
    expect(answer.report.lines, isEmpty);
  });

  test('an error the engine reports fails the search in words', () async {
    final (engine, process) = await started();
    process.next = [
      'info string hb_error position illegal move 1e2e5',
      'info depth 0 nodes 0 time 1',
      'bestmove (pass,pass)',
    ];
    final answer = await engine.search(question(coordination: true));
    expect(
      (answer as HypeBeastFailed).reason,
      'The bughouse engine could not play the moves that led here.',
    );
    process.next = [
      'info string hb_error illegal_decision reason=x using_fallback',
      'info depth 9 score cp 3 nodes 900 time 10',
      'bestmove (e2e4,pass)',
    ];
    expect(
      (await engine.search(question(coordination: true)) as HypeBeastFailed)
          .reason,
      'The bughouse engine reported an error.',
    );
  });

  test('a sit without a node searched, where there are moves, fails', () async {
    final (engine, process) = await started();
    process.next = ['bestmove (pass,pass)'];
    final answer = await engine.search(question(coordination: true));
    expect(
      (answer as HypeBeastFailed).reason,
      'The bughouse engine did not search the table.',
    );
  });

  test('a sit is a decision to pass', () async {
    final (engine, process) = await started();
    process.next = ['info depth 0 nodes 40 time 1', 'bestmove (pass,pass)'];
    final answer =
        await engine.search(question(coordination: true)) as HypeBeastSearched;
    expect(answer.decision!.sits, isTrue);
  });

  test('searches asked together are answered in turn', () async {
    final (engine, process) = await started();
    process.next = aloneSearch;
    final first = engine.search(question());
    final second = engine.search(question(lines: 1));
    await first;
    expect(process.asked.where((l) => l.startsWith('go')).length, 1);
    process.next = ['bestmove (e2e3,pass)'];
    final answer = await second as HypeBeastSearched;
    expect(answer.decision, const SeatDecision('e2e3'));
  });

  test(
    'stop cuts the running search short; its answer keeps what it found',
    () async {
      final (engine, process) = await started();
      final searching = engine.search(question());
      await pumpEventQueue();
      process.say(aloneSearch.first);
      await pumpEventQueue();
      engine.stop();
      expect(process.sent.last, 'stop');
      process.say('bestmove (d2d4,pass)');
      final answer = await searching as HypeBeastSearched;
      expect(answer.decision, const SeatDecision('d2d4'));
      expect(answer.report.main!.cp, 92);
    },
  );

  test('stop while the engine is still getting ready cuts the search as '
      'soon as it starts', () async {
    final (engine, process) = await started();
    process.holdReady = true;
    process.next = aloneSearch;
    final answer = engine.search(question());
    await Future<void>.delayed(Duration.zero);
    expect(process.sent.last, 'isready');
    engine.stop();
    expect(process.sent.last, 'isready', reason: 'nothing to stop yet');
    process.ready();
    final found = await answer as HypeBeastSearched;
    final go = process.sent.indexOf('go nodes 2000');
    expect(process.sent.sublist(go), ['go nodes 2000', 'stop']);
    expect(found.decision, const SeatDecision('e2e4'));
  });

  test('an engine that dies mid-search fails the search in words', () async {
    final (engine, process) = await started();
    final searching = engine.search(question());
    await pumpEventQueue();
    process.crash();
    expect(
      (await searching as HypeBeastFailed).reason,
      'The bughouse engine stopped.',
    );
    expect(await engine.exited, EngineExit.ended);
    expect(await engine.search(question()), isA<HypeBeastFailed>());
  });

  test('a search that goes quiet for its patience is killed', () {
    fakeAsync((time) {
      final process = AnsweringProcess();
      final engine = startFake(time, process);
      HypeBeastAnswer? answer;
      unawaited(
        engine
            .search(question(budget: const NodeBudget(900000000)))
            .then((a) => answer = a),
      );
      // Reports keep it alive well past ten minutes of searching.
      for (var minute = 0; minute < 15; minute++) {
        time.elapse(const Duration(minutes: 1));
        process.say(
          'info depth ${minute + 1} seldepth 9 multipv 1 score cp 30 '
          'nodes ${1000 * minute + 2} pv e2e4',
        );
        time.flushMicrotasks();
      }
      expect(process.killed, isFalse);
      EngineExit? exit;
      unawaited(engine.exited.then((e) => exit = e));
      time.elapse(const Duration(minutes: 11));
      expect(process.killed, isTrue);
      expect((answer as HypeBeastFailed).reason, contains('stopped answering'));
      expect(exit, EngineExit.unresponsive);
    });
  });

  test('a stopped search that never answers releases the queue after the '
      'grace', () {
    fakeAsync((time) {
      final process = AnsweringProcess();
      final engine = startFake(time, process);
      HypeBeastAnswer? stopped;
      HypeBeastAnswer? next;
      unawaited(engine.search(question()).then((a) => stopped = a));
      time.flushMicrotasks();
      process.say(aloneSearch.first);
      time.flushMicrotasks();
      engine.stop();
      unawaited(engine.search(question(lines: 1)).then((a) => next = a));
      for (var second = 0; second < 29; second++) {
        time.elapse(const Duration(seconds: 1));
        process.say(
          'info depth 3 seldepth 4 multipv 1 score cp 9 nodes ${100 + second} '
          'pv e2e4',
        );
        time.flushMicrotasks();
      }
      expect(stopped, isNull);
      time.elapse(const Duration(seconds: 1));
      expect(stopped, isA<HypeBeastFailed>());
      // The engine was killed as wedged; the next search is told so.
      expect(next, isA<HypeBeastFailed>());
    });
  });

  test('an engine that takes seconds to answer stop keeps its search', () {
    fakeAsync((time) {
      final process = AnsweringProcess();
      final engine = startFake(time, process);
      HypeBeastAnswer? stopped;
      unawaited(engine.search(question()).then((a) => stopped = a));
      time.flushMicrotasks();
      process.say(aloneSearch.first);
      time.flushMicrotasks();
      engine.stop();
      time.elapse(const Duration(seconds: 8));
      process.say('bestmove (d2d4,pass)');
      time.flushMicrotasks();
      expect(stopped, isA<HypeBeastSearched>());
      expect(process.killed, isFalse);
    });
  });

  for (final budget in [
    const NodeBudget(200),
    const TimeBudget(Duration(seconds: 2)),
  ]) {
    test('${budget.go} expires despite increasing reports', () {
      fakeAsync((time) {
        final process = AnsweringProcess();
        final engine = startFake(time, process);
        HypeBeastAnswer? answer;
        unawaited(
          engine.search(question(budget: budget)).then((a) => answer = a),
        );
        time.flushMicrotasks();
        for (var second = 0; second < 62; second++) {
          process.say(
            'info depth ${second + 1} seldepth 9 multipv 1 score cp 10 '
            'nodes ${200 + second} pv d2d4',
          );
          time.elapse(const Duration(seconds: 1));
        }
        expect(answer, isA<HypeBeastFailed>());
        expect(process.killed, isTrue);
      });
    });
  }

  test('an engine that never answers bestmove is killed', () {
    fakeAsync((time) {
      final process = AnsweringProcess();
      final engine = startFake(time, process);
      HypeBeastAnswer? answer;
      unawaited(engine.search(question()).then((a) => answer = a));
      EngineExit? exit;
      unawaited(engine.exited.then((e) => exit = e));
      time.elapse(const Duration(minutes: 11));
      expect(process.killed, isTrue);
      expect((answer as HypeBeastFailed).reason, contains('stopped answering'));
      expect(exit, EngineExit.unresponsive);
    });
  });

  test('an engine that never handshakes is killed and not started', () {
    fakeAsync((time) {
      final process = AnsweringProcess(silent: true);
      HypeBeastProcess? engine;
      var done = false;
      unawaited(
        HypeBeastProcess.start(
          process,
          net: _net,
          patience: const Duration(seconds: 5),
        ).then((e) {
          engine = e;
          done = true;
        }),
      );
      time.elapse(const Duration(seconds: 6));
      expect(done, isTrue);
      expect(engine, isNull);
      expect(process.killed, isTrue);
    });
  });

  test('quit ends the process', () async {
    final (engine, process) = await started();
    await engine.quit();
    expect(process.sent.last, 'quit');
    expect(await engine.exited, EngineExit.ended);
  });

  test('a search on a clock is given a minute more than its time', () {
    expect(
      const TimeBudget(Duration(seconds: 10)).patience,
      const Duration(seconds: 70),
    );
    expect(const TimeBudget(Duration(seconds: 10)).go, 'go movetime 10000');
  });
}

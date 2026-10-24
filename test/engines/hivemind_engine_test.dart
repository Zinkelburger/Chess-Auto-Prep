import 'dart:async';

import 'package:chess_auto_prep/chess/bughouse/hivemind.dart';
import 'package:chess_auto_prep/chess/bughouse/table.dart';
import 'package:chess_auto_prep/engines/engine.dart';
import 'package:chess_auto_prep/engines/hivemind_engine.dart';
import 'package:chess_auto_prep/engines/uci_process.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

/// A Hivemind that answers the way the real one does, from lines the test
/// gives each `go`: `uciok`, `readyok`, the search's `info` lines and its
/// `bestmove`. Lines printed by a real 200-node search of the start.
final class AnsweringProcess implements UciProcess {
  AnsweringProcess({this.silent = false, this.live = false});

  /// Says nothing at all, as a binary that never reaches `main`.
  final bool silent;

  /// Offers `ReportIntervalMs`, off by default as upstream Hivemind has it.
  final bool live;
  final sent = <String>[];
  final searches = <List<String>>[];
  final _out = StreamController<String>();
  bool killed = false;

  /// What the next `go` prints; left unset, the search never ends.
  List<String>? next;

  @override
  int get pid => 4343;

  @override
  Stream<String> get lines => _out.stream;

  @override
  void send(String line) {
    sent.add(line);
    if (silent || _out.isClosed) return;
    if (line == 'uci') {
      say('id name hivemind');
      say('option name MultiPV type spin default 1 min 1 max 500');
      if (live) {
        say('option name ReportIntervalMs type spin default 0 min 0 max 60000');
      }
      say('uciok');
    } else if (line == 'isready') {
      say('readyok');
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
}

const startSearch = [
  'info string root width 20 generated',
  'info depth 1 multipv 1 score cp -16671 nodes 1 nps 1 time 0 pv (d2d4,pass)',
  'info depth 3 multipv 1 score cp -228 nodes 245 nps 249 time 981 pv (d2d4,pass) (d7d5,d2d4)',
  'info depth 3 multipv 2 score cp -231 nodes 245 nps 249 time 981 pv (e2e4,pass) (e7e5,e2e4)',
  'info depth 3 multipv 3 score cp -200 nodes 245 nps 249 time 981 pv (g1f3,pass) (d7d5,d2d4)',
  'bestmove (d2d4,pass) ponder (d7d5,d2d4)',
];

HivemindQuestion question({
  Team team = Team.ab,
  bool maySit = false,
  MustMove mustMove = MustMove.either,
  int lines = 3,
  HivemindBudget budget = const NodeBudget(200),
}) => (
  position: TablePosition.initial,
  team: team,
  maySit: maySit,
  mustMove: mustMove,
  lines: lines,
  budget: budget,
);

/// Two reports of a live search, the second block one line short (the
/// third move not yet visited), then the final block and bestmove.
const liveSearch = [
  'info depth 2 multipv 1 score cp -221 nodes 12 nps 73 time 163 pv (e2e4,pass) (e7e5,e2e4)',
  'info depth 2 multipv 2 score cp -259 nodes 12 nps 73 time 163 pv (g2g3,pass)',
  'info depth 2 multipv 3 score cp -232 nodes 12 nps 73 time 163 pv (d2d3,pass)',
  'info depth 3 multipv 1 score cp -218 nodes 60 nps 111 time 539 pv (d2d4,pass) (d7d5,e2e4)',
  'info depth 3 multipv 2 score cp -210 nodes 60 nps 111 time 539 pv (e2e4,pass)',
  'info depth 3 multipv 1 score cp -228 nodes 245 nps 249 time 981 pv (d2d4,pass) (d7d5,d2d4)',
  'info depth 3 multipv 2 score cp -231 nodes 245 nps 249 time 981 pv (e2e4,pass) (e7e5,e2e4)',
  'info depth 3 multipv 3 score cp -200 nodes 245 nps 249 time 981 pv (g1f3,pass) (d7d5,d2d4)',
  'info string root width 20 generated',
  'bestmove (d2d4,pass) ponder (d7d5,d2d4)',
];

void main() {
  Future<(HivemindProcess, AnsweringProcess)> started({
    bool live = false,
  }) async {
    final process = AnsweringProcess(live: live);
    final engine = await HivemindProcess.start(
      process,
      options: {'Hash': '256'},
    );
    return (engine!, process);
  }

  test('the handshake sets the options and waits for readyok', () async {
    final (engine, process) = await started();
    expect(engine.provenance['engine_name'], 'hivemind');
    expect(engine.provenance['options'], {'Hash': '256'});
    expect(process.sent, ['uci', 'setoption name Hash value 256', 'isready']);
  });

  test('an engine that offers ReportIntervalMs streams; one that does not, '
      'does not', () async {
    final (live, liveProcess) = await started(live: true);
    expect(live.streams, isTrue);
    expect(
      liveProcess.sent,
      contains('setoption name ReportIntervalMs value 250'),
    );
    final (old, _) = await started();
    expect(old.streams, isFalse);
  });

  test('a live search hands on each block as it is printed', () async {
    final (engine, process) = await started(live: true);
    process.next = liveSearch;
    final reports = <List<JointLine>>[];
    final answer =
        await engine.search(question(), onLines: reports.add)
            as HivemindSearched;
    // The short block is handed on when the next one starts; the final
    // block is the answer.
    expect(reports.map((r) => r.first.nodes), [12, 60, 245]);
    expect(reports[0].map((l) => l.rank), [1, 3, 2]);
    expect(reports[1].map((l) => l.rank), [1, 2]);
    expect(reports[1].first.pv.first, const JointMove('d2d4', null));
    expect(answer.lines.map((l) => (l.rank, l.nodes)), [
      (1, 245),
      (3, 245),
      (2, 245),
    ]);
    expect(answer.best, const JointMove('d2d4', null));
  });

  test('a live search that goes quiet for its patience is killed', () {
    fakeAsync((time) {
      late HivemindProcess engine;
      final process = AnsweringProcess(live: true);
      unawaited(HivemindProcess.start(process).then((e) => engine = e!));
      time.flushMicrotasks();
      HivemindAnswer? answer;
      unawaited(engine.search(question()).then((a) => answer = a));
      // Reports keep it alive well past ten minutes of searching.
      for (var minute = 0; minute < 15; minute++) {
        time.elapse(const Duration(minutes: 1));
        process.say(
          'info depth 4 multipv 1 score cp -230 nodes ${1000 * minute + 2} '
          'pv (d2d4,pass)',
        );
        time.flushMicrotasks();
      }
      expect(process.killed, isFalse);
      time.elapse(const Duration(minutes: 11));
      expect(process.killed, isTrue);
      expect((answer as HivemindFailed).reason, contains('stopped answering'));
    });
  });

  test('a search reads the joint lines, rank 1 first, then by score', () async {
    final (engine, process) = await started();
    process.next = startSearch;
    final answer = await engine.search(question()) as HivemindSearched;
    expect(answer.best, const JointMove('d2d4', null));
    expect(answer.lines.map((l) => l.rank), [1, 3, 2]);
    expect(answer.top!.cp, -228);
    expect(answer.top!.depth, 3);
    expect(answer.top!.nodes, 245);
    expect(answer.top!.pv.last, const JointMove('d7d5', 'd2d4'));
    // The root's unvisited prior never reads as a score.
    expect(answer.lines.any((l) => l.cp == -16671), isFalse);
  });

  test('a mate the root scan decides at one node is read', () async {
    final (engine, process) = await started();
    process.next = [
      'info depth 1 score mate 1 nodes 1 nps 1000 time 0 pv (d8h4,a2a3)',
      'bestmove (d8h4,a2a3)',
    ];
    final answer =
        await engine.search(question(team: Team.cd)) as HivemindSearched;
    expect(answer.top!.mate, 1);
    expect(answer.top!.pv.single, const JointMove('d8h4', 'a2a3'));
  });

  test('a search tells the engine the team, the clock and the rule', () async {
    final (engine, process) = await started();
    process.next = startSearch;
    await engine.search(
      question(team: Team.cd, maySit: true, mustMove: MustMove.two, lines: 1),
    );
    expect(
      process.sent,
      containsAllInOrder([
        'setoption name Team value black',
        'setoption name TimeAdvantage value true',
        'setoption name RequireMoveOn value B',
        'setoption name MultiPV value 1',
        'isready',
        'position fen ${TablePosition.initial.dualFen}',
        'go nodes 200',
        'stop',
      ]),
    );
  });

  test('options that have not changed are not sent again', () async {
    final (engine, process) = await started();
    process.next = startSearch;
    await engine.search(question());
    process.sent.clear();
    process.next = startSearch;
    await engine.search(
      question(budget: const TimeBudget(Duration(seconds: 3))),
    );
    expect(process.sent.where((l) => l.startsWith('setoption')), isEmpty);
    expect(process.sent, contains('go movetime 3000'));
  });

  test(
    'what the engine prints after a search never lands in the next',
    () async {
      final (engine, process) = await started();
      process.next = startSearch;
      await engine.search(question());
      // Thinking on after bestmove, until the stop that followed it.
      process.say(
        'info depth 9 multipv 1 score cp 999 nodes 500 pv (e2e4,pass)',
      );
      process.say('bestmove (e2e4,pass)');
      process.next = ['bestmove (none)'];
      final answer = await engine.search(question()) as HivemindSearched;
      expect(answer.best, isNull);
      expect(answer.lines, isEmpty);
    },
  );

  test('a team with no move gets no action and no lines', () async {
    final (engine, process) = await started();
    process.next = ['bestmove (none)'];
    final answer = await engine.search(question()) as HivemindSearched;
    expect(answer.best, isNull);
    expect(answer.top, isNull);
  });

  test('searches asked together are answered in turn', () async {
    final (engine, process) = await started();
    process.next = startSearch;
    final first = engine.search(question());
    final second = engine.search(question(lines: 1));
    await first;
    expect(process.sent.where((l) => l.startsWith('go')).length, 1);
    process.next = ['bestmove (e2e4,pass)'];
    final answer = await second as HivemindSearched;
    expect(answer.best, const JointMove('e2e4', null));
  });

  test('stop cuts the running search short', () async {
    final (engine, process) = await started();
    final searching = engine.search(question());
    await pumpEventQueue();
    engine.stop();
    expect(process.sent.last, 'stop');
    process.say('bestmove (d2d4,pass)');
    expect((await searching as HivemindSearched).best, isNotNull);
  });

  test('an engine that dies mid-search fails the search in words', () async {
    final (engine, process) = await started();
    final searching = engine.search(question());
    await pumpEventQueue();
    process.crash();
    expect(
      (await searching as HivemindFailed).reason,
      'The bughouse engine stopped.',
    );
    expect(await engine.exited, EngineExit.ended);
    expect(await engine.search(question()), isA<HivemindFailed>());
  });

  test('an engine that never answers bestmove is killed', () {
    fakeAsync((time) {
      late HivemindProcess engine;
      final process = AnsweringProcess();
      unawaited(HivemindProcess.start(process).then((e) => engine = e!));
      time.flushMicrotasks();
      HivemindAnswer? answer;
      unawaited(engine.search(question()).then((a) => answer = a));
      time.elapse(const Duration(minutes: 11));
      expect(process.killed, isTrue);
      expect((answer as HivemindFailed).reason, contains('stopped answering'));
    });
  });

  test('an engine that never handshakes is killed and not started', () {
    fakeAsync((time) {
      final process = AnsweringProcess(silent: true);
      HivemindProcess? engine;
      var done = false;
      unawaited(
        HivemindProcess.start(
          process,
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

  group('info lines', () {
    test('a mate is read as plies for the searched team', () {
      final line = parseHivemindInfo(
        'info depth 5 multipv 1 score mate 3 nodes 900 pv (P@f7,pass)',
      )!;
      expect(line.mate, 3);
      expect(line.q, isNull);
      expect(line.pv.single, const JointMove('P@f7', null));
    });

    test('an info string is not a line', () {
      expect(parseHivemindInfo('info string backend ONNX Runtime'), isNull);
    });

    test('bestmove (none) is no action', () {
      expect(parseBestMove('bestmove (none)'), isNull);
      expect(
        parseBestMove('bestmove (pass,e7e5)'),
        const JointMove(null, 'e7e5'),
      );
    });
  });
}

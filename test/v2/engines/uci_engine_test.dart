import 'dart:async';

import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/engines/engine.dart';
import 'package:chess_auto_prep/v2/engines/engine_line.dart';
import 'package:chess_auto_prep/v2/engines/uci_engine.dart';
import 'package:chess_auto_prep/v2/engines/uci_process.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

/// The far end of the pipe, played by the test.
final class FakeProcess implements UciProcess {
  final sent = <String>[];
  final _out = StreamController<String>();
  bool killed = false;
  bool _gone = false;

  @override
  int get pid => 4242;

  @override
  Stream<String> get lines => _out.stream;

  @override
  void send(String line) => sent.add(line);

  @override
  Future<void> kill() async {
    killed = true;
    exit(137);
  }

  void say(String line) => _out.add(line);

  /// The process goes. [code] is what a real one would report: 139 for a
  /// crash, 137 for the kill above.
  void exit(int code) {
    if (_gone) return;
    _gone = true;
    unawaited(_out.close());
  }

  void answerHandshake() {
    say('id name Fake 9');
    say('uciok');
    say('readyok');
  }
}

void main() {
  const after1e4 = Fen(
    'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
  );

  Future<(UciEngine, FakeProcess)> started() async {
    final process = FakeProcess();
    final starting = UciEngine.start(process, options: {'Hash': '16'});
    await pumpEventQueue();
    process.answerHandshake();
    return (await starting, process);
  }

  test('handshakes, applies options and takes the name', () async {
    final (engine, process) = await started();
    expect(process.sent, ['uci', 'setoption name Hash value 16', 'isready']);
    expect(engine.name, 'Fake 9');
  });

  test('a search sends the position and receives its lines', () async {
    final (engine, process) = await started();
    final search = engine.analyse(Fen.initial, multiPv: 2);
    final lines = <EngineLine>[];
    search.lines.listen(lines.add);
    await pumpEventQueue();
    expect(process.sent.sublist(3), [
      'setoption name MultiPV value 2',
      'position fen ${Fen.initial.value}',
      'go infinite',
    ]);
    process.say('info depth 5 multipv 1 score cp 20 pv e2e4');
    process.say('info depth 5 multipv 2 score cp 15 pv d2d4');
    await pumpEventQueue();
    expect(lines.map((l) => l.pv.single), ['e2e4', 'd2d4']);
  });

  test(
    'a new search waits for the old bestmove, and old lines stay old',
    () async {
      final (engine, process) = await started();
      final first = engine.analyse(Fen.initial, multiPv: 1);
      final firstLines = <EngineLine>[];
      var firstDone = false;
      first.lines.listen(firstLines.add, onDone: () => firstDone = true);
      await pumpEventQueue();
      final second = engine.analyse(after1e4, multiPv: 1);
      final secondLines = <EngineLine>[];
      second.lines.listen(secondLines.add);
      await pumpEventQueue();
      expect(process.sent.last, 'stop');
      // The engine is still finishing the first search.
      process.say('info depth 30 score cp 40 pv e2e4');
      await pumpEventQueue();
      expect(firstLines, hasLength(1));
      expect(secondLines, isEmpty);
      expect(process.sent.last, 'stop', reason: 'no go before bestmove');
      process.say('bestmove e2e4');
      await pumpEventQueue();
      expect(firstDone, isTrue);
      expect(process.sent.last, 'go infinite');
      expect(process.sent, contains('position fen ${after1e4.value}'));
      process.say('info depth 1 score cp -30 pv e7e5');
      await pumpEventQueue();
      expect(secondLines.single.pv, ['e7e5']);
      expect(firstLines, hasLength(1));
    },
  );

  test('a fixed-depth search sends go depth and ends on its own; a search '
      'queued behind it waits rather than stopping it', () async {
    final (engine, process) = await started();
    final fixed = engine.analyse(Fen.initial, multiPv: 1, depth: 12);
    var fixedDone = false;
    fixed.lines.listen(null, onDone: () => fixedDone = true);
    await pumpEventQueue();
    expect(process.sent.last, 'go depth 12');
    final next = engine.analyse(after1e4, multiPv: 1);
    next.lines.listen(null);
    await pumpEventQueue();
    expect(process.sent, isNot(contains('stop')));
    expect(process.sent.last, 'go depth 12', reason: 'still waiting');
    process.say('info depth 12 score cp 20 pv e2e4');
    process.say('bestmove e2e4');
    await pumpEventQueue();
    expect(fixedDone, isTrue);
    expect(process.sent.last, 'go infinite');
  });

  test('stopping a queued search cancels it without a go', () async {
    final (engine, process) = await started();
    engine.analyse(Fen.initial, multiPv: 1);
    await pumpEventQueue();
    final queued = engine.analyse(after1e4, multiPv: 1);
    var done = false;
    queued.lines.listen(null, onDone: () => done = true);
    await queued.stop();
    process.say('bestmove e2e4');
    await pumpEventQueue();
    expect(done, isTrue);
    expect(process.sent.where((l) => l == 'go infinite'), hasLength(1));
  });

  test('stop completes when the engine says bestmove', () async {
    final (engine, process) = await started();
    final search = engine.analyse(Fen.initial, multiPv: 1);
    await pumpEventQueue();
    var stopped = false;
    unawaited(search.stop().then((_) => stopped = true));
    unawaited(search.stop()); // asking twice sends one stop
    await pumpEventQueue();
    expect(stopped, isFalse);
    expect(process.sent.where((l) => l == 'stop'), hasLength(1));
    process.say('bestmove e2e4');
    await pumpEventQueue();
    expect(stopped, isTrue);
  });

  test('quit waits for the exit, then kills', () {
    fakeAsync((async) {
      final process = FakeProcess();
      final starting = UciEngine.start(process);
      async.flushMicrotasks();
      process.answerHandshake();
      async.flushMicrotasks();
      late UciEngine engine;
      unawaited(starting.then((e) => engine = e));
      async.flushMicrotasks();
      var gone = false;
      unawaited(engine.quit().then((_) => gone = true));
      async.elapse(const Duration(seconds: 1));
      expect(process.sent.last, 'quit');
      expect(gone, isFalse);
      async.elapse(const Duration(seconds: 2));
      expect(process.killed, isTrue);
      expect(gone, isTrue);
    });
  });

  test('an engine that never answers stop is killed, not waited on', () {
    fakeAsync((async) {
      final process = FakeProcess();
      final starting = UciEngine.start(process);
      async.flushMicrotasks();
      process.answerHandshake();
      async.flushMicrotasks();
      late UciEngine engine;
      unawaited(starting.then((e) => engine = e));
      async.flushMicrotasks();

      final first = engine.analyse(Fen.initial, multiPv: 1);
      var firstDone = false;
      first.lines.listen(null, onDone: () => firstDone = true);
      async.flushMicrotasks();
      final second = engine.analyse(after1e4, multiPv: 1);
      var secondDone = false;
      second.lines.listen(null, onDone: () => secondDone = true);
      async.flushMicrotasks();
      expect(process.sent.last, 'stop');

      // The engine says nothing at all: no `bestmove`, no exit.
      async.elapse(const Duration(seconds: 30));
      async.flushMicrotasks();

      expect(process.killed, isTrue, reason: 'the pane cannot wait for ever');
      expect(firstDone, isTrue);
      expect(secondDone, isTrue);
      expect(
        process.sent,
        isNot(contains('position fen ${after1e4.value}')),
        reason: 'nothing is asked of an engine that has gone',
      );
    });
  });

  test('an engine that exits mid-handshake fails to start', () async {
    final process = FakeProcess();
    final starting = UciEngine.start(process);
    await pumpEventQueue();
    process.exit(1);
    await expectLater(starting, throwsA(isA<EngineFailure>()));
  });

  test('an engine that dies ends its search and reports exit', () async {
    final (engine, process) = await started();
    final search = engine.analyse(Fen.initial, multiPv: 1);
    var done = false;
    search.lines.listen(null, onDone: () => done = true);
    await pumpEventQueue();
    process.exit(139);
    await engine.exited;
    await pumpEventQueue();
    expect(done, isTrue);
  });
}

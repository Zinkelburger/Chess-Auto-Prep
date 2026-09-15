import 'package:chess_auto_prep/features/engine_tournament/services/uci_search_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the last principal-variation score wins', () {
    final tracker = UciSearchTracker()
      ..observeInfo('info depth 10 score cp 20 nodes 1000 pv e2e4')
      ..observeInfo('info depth 12 score cp 31 nodes 5000 pv e2e4 e7e5');
    final search = tracker.finish('bestmove e2e4 ponder e7e5');
    expect(search.bestMoveUci, 'e2e4');
    expect(search.ponderUci, 'e7e5');
    expect(search.scoreCp, 31);
    expect(search.scoreMate, isNull);
    expect(search.depth, 12);
    expect(search.nodes, 5000);
  });

  test('a mate score replaces a centipawn score and vice versa', () {
    final tracker = UciSearchTracker()
      ..observeInfo('info depth 8 score cp 500')
      ..observeInfo('info depth 9 score mate 3');
    expect(tracker.scoreMate, 3);
    expect(tracker.scoreCp, isNull);
    tracker.observeInfo('info depth 10 score cp 900');
    expect(tracker.scoreCp, 900);
    expect(tracker.scoreMate, isNull);
  });

  test('lower MultiPV lines never overwrite the best line', () {
    final tracker = UciSearchTracker()
      ..observeInfo('info depth 12 multipv 1 score cp 40 pv e2e4')
      ..observeInfo('info depth 12 multipv 2 score cp -10 pv d2d4');
    expect(tracker.scoreCp, 40);
  });

  test('"info string" chatter is ignored even when it names keys', () {
    final tracker = UciSearchTracker()
      ..observeInfo('info depth 5 score cp 12')
      ..observeInfo('info string depth 99 score cp 999');
    expect(tracker.depth, 5);
    expect(tracker.scoreCp, 12);
  });

  test('a line without a score leaves the last score standing', () {
    final tracker = UciSearchTracker()
      ..observeInfo('info depth 5 score cp 12')
      ..observeInfo('info depth 6 nodes 42 currmove e2e4');
    expect(tracker.scoreCp, 12);
    expect(tracker.depth, 6);
    expect(tracker.nodes, 42);
  });

  test('runs of whitespace are tolerated', () {
    final tracker = UciSearchTracker()
      ..observeInfo('info   depth 7   score   cp   -5');
    expect(tracker.depth, 7);
    expect(tracker.scoreCp, -5);
  });

  test('a bare bestmove has no move and no ponder', () {
    final search = UciSearchTracker().finish('bestmove');
    expect(search.bestMoveUci, '');
    expect(search.hasMove, isFalse);
    expect(search.ponderUci, isNull);
  });

  test('elapsed time comes from the tracker\'s own clock', () {
    final clock = Stopwatch();
    final tracker = UciSearchTracker(clock: clock);
    expect(clock.isRunning, isTrue);
    final search = tracker.finish('bestmove (none)');
    expect(clock.isRunning, isFalse);
    expect(search.elapsedMs, clock.elapsedMilliseconds);
    expect(search.hasMove, isFalse);
  });
}

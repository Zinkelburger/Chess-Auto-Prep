import 'dart:async';

import 'package:chess_auto_prep/services/engine/engine_search_budget.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('FIFO admission, elastic threads, and idempotent release', () async {
    final budget = EngineSearchBudget(capacity: () => 2);
    final first = await budget.acquire(1, EngineSearchCancellation());
    final second = await budget.acquire(8, EngineSearchCancellation());
    expect(second.threads, 1);
    expect(budget.activeThreads, 2);
    final order = <int>[];
    final third = budget.acquire(2, EngineSearchCancellation());
    unawaited(third.then((_) => order.add(3)));
    final fourth = budget.acquire(1, EngineSearchCancellation());
    unawaited(fourth.then((_) => order.add(4)));
    first.release();
    first.release();
    final allocation3 = await third;
    expect(order, [3]);
    expect(allocation3.threads, 1);
    second.release();
    final allocation4 = await fourth;
    expect(order, [3, 4]);
    expect(budget.activeThreads, 2);
    allocation3.release();
    allocation4.release();
    expect(budget.activeThreads, 0);
  });

  test(
    'queued cancellation releases its place without spending threads',
    () async {
      final budget = EngineSearchBudget(capacity: () => 1);
      final held = await budget.acquire(1, EngineSearchCancellation());
      final cancellation = EngineSearchCancellation();
      final pending = budget.acquire(1, cancellation);
      final cancelled = expectLater(
        pending,
        throwsA(isA<EngineSearchCancelled>()),
      );
      cancellation.cancel();
      await cancelled;
      held.release();
      expect(budget.activeThreads, 0);
      final next = await budget.acquire(1, EngineSearchCancellation());
      next.release();
    },
  );

  test('lower capacity takes effect at search boundaries', () async {
    var capacity = 2;
    final budget = EngineSearchBudget(capacity: () => capacity);
    final held = await budget.acquire(2, EngineSearchCancellation());
    capacity = 1;
    final pending = budget.acquire(2, EngineSearchCancellation());
    expect(budget.activeThreads, 2);
    held.release();
    final next = await pending;
    expect(next.threads, 1);
    next.release();
  });
}

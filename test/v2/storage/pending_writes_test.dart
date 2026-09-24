import 'dart:async';

import 'package:chess_auto_prep/v2/storage/pending_writes.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'an old snapshot completion cannot clear a newer snapshot failure',
    () async {
      final writes = PendingWrites();
      final owner = Object();
      final first = Completer<bool>();
      final old = writes.track(
        owner,
        first.future,
        label: 'Snapshots',
        obligation: owner,
        problem: (ok) => ok ? null : 'old failure',
      );
      await writes.track(
        owner,
        Future.value(false),
        label: 'Snapshots',
        obligation: owner,
        problem: (ok) => ok ? null : 'new failure',
      );
      first.complete(true);
      await old;
      expect(await writes.settle(), contains('new failure'));
    },
  );
  test('unrelated successful work cannot clear a resource failure', () async {
    final writes = PendingWrites();
    final resource = Object();
    await writes.track(
      resource,
      Future.value(false),
      label: 'First',
      problem: (value) => value ? null : 'not saved',
    );
    await writes.track(resource, Future.value(true), label: 'Second');
    expect(await writes.settle(), contains('First: not saved'));
  });

  test('same obligation retry clears only its own failed result', () async {
    final writes = PendingWrites();
    final resource = Object();
    var saved = false;
    final first = writes.accept<bool>(
      resource: resource,
      label: 'First',
      work: () async => saved,
      problem: (value) => value ? null : 'not saved',
    );
    final second = writes.accept<bool>(
      resource: resource,
      label: 'Second',
      work: () async => false,
      problem: (value) => value ? null : 'still unsaved',
    );
    await first.run();
    await second.run();
    saved = true;
    await first.run();
    expect(await writes.settle(), 'Second: still unsaved');
    expect(writes.unfinished(resource), [second]);
  });

  test(
    'resource barriers wait across replacements without draining others',
    () async {
      final writes = PendingWrites();
      final resource = Object();
      final finish = Completer<void>();
      final unrelated = Completer<void>();
      writes.watch(resource, finish.future);
      writes.watch(Object(), unrelated.future);
      var passed = 0;
      final first = writes.settleFor(resource).then((_) => passed++);
      final second = writes.settleFor(resource).then((_) => passed++);
      await pumpEventQueue();
      expect(passed, 0);
      finish.complete();
      await Future.wait([first, second]);
      expect(passed, 2);
      unrelated.complete();
      expect(await writes.settle(), isNull);
    },
  );
}

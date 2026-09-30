import 'dart:async';

import 'package:chess_auto_prep/storage/pending_writes.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'explicit discard cannot abandon active work and unblocks successors',
    () async {
      final writes = PendingWrites();
      final resource = Object();
      final finish = Completer<bool>();
      final first = writes.accept<bool>(
        resource: resource,
        label: 'First',
        work: () => finish.future,
        problem: (ok) => ok ? null : 'permanent failure',
      );
      final running = first.run();
      expect(first.discard(), isFalse);
      finish.complete(false);
      await running;
      final second = writes.accept<bool>(
        resource: resource,
        label: 'Second',
        work: () async => true,
        problem: (ok) => ok ? null : 'blocked',
        blocked: () => false,
      );
      expect(await second.run(), isFalse);
      expect(first.discard(), isTrue);
      expect(first.committed, isFalse);
      expect(await second.run(), isTrue);
      expect(await writes.settle(), isNull);
      await expectLater(first.run(), throwsStateError);
    },
  );

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
      obligation: 'first',
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

  group('an obligation whose owner takes a recorded operation as accepted', () {
    // As line moves and study renames ask: the journal finishes an
    // operation it recorded, so only one it did not record needs the user.
    String? problem(SaveResult result) =>
        result is IoFailure && result is! Unfinished ? result.detail : null;

    test('settles when answered Unfinished, and exit asks nothing', () async {
      final writes = PendingWrites();
      final resource = Object();
      final move = writes.accept<SaveResult>(
        resource: resource,
        label: 'Move',
        work: () async => const Unfinished('held open by another program'),
        problem: problem,
      );
      final next = writes.accept<SaveResult>(
        resource: resource,
        label: 'Next',
        work: () async => const Conflict(null),
        problem: problem,
        blocked: () => const IoFailure('blocked'),
      );
      await move.run();
      expect(move.committed, isTrue);
      expect(await next.run(), isA<Conflict>());
      expect(writes.unfinished(resource), isEmpty);
      expect(await writes.settle(), isNull);
    });

    test('still reports one answered with a plain IoFailure', () async {
      final writes = PendingWrites();
      final resource = Object();
      final move = writes.accept<SaveResult>(
        resource: resource,
        label: 'Move',
        work: () async => const IoFailure('nothing recorded'),
        problem: problem,
      );
      await move.run();
      expect(move.committed, isFalse);
      expect(writes.unfinished(resource), [move]);
      expect(await writes.settle(), 'Move: nothing recorded');
    });
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

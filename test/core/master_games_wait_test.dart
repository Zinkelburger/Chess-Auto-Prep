// MasterGamesWait: parking a run on the master-games download, joining a
// sync already in flight, and releasing the wait from either side.

import 'dart:async';

import 'package:chess_auto_prep/core/master_games_wait.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeSync extends ChangeNotifier implements MasterGamesSync {
  _FakeSync({this.isSyncing = false});

  @override
  bool isSyncing;

  @override
  String status = '';

  final Completer<void> done = Completer<void>();
  int syncCalls = 0;
  int cancelCalls = 0;
  Object? failWith;

  @override
  Future<void> sync() {
    syncCalls++;
    isSyncing = true;
    if (failWith != null) return Future.error(failWith!);
    return done.future;
  }

  @override
  Future<void> get syncCompletion => done.future;

  @override
  void cancel() {
    cancelCalls++;
    if (!done.isCompleted) done.complete();
  }

  void report(String line) {
    status = line;
    notifyListeners();
  }
}

/// Lets the parked future reach its await.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  test(
    'starts a download when none is running and stops it on release',
    () async {
      final sync = _FakeSync();
      final wait = MasterGamesWait();
      final statuses = <String>[];

      final parked = wait.park(sync, onStatus: statuses.add);
      await _settle();
      expect(wait.isWaiting, isTrue);
      expect(sync.syncCalls, 1);

      sync.report('');
      sync.report('TWIC 1650 imported');
      expect(statuses, [
        MasterGamesWait.downloadingStatus,
        'TWIC 1650 imported',
      ]);

      wait.stopWaiting();
      await parked;
      expect(wait.isWaiting, isFalse);
      expect(sync.cancelCalls, 1, reason: 'ours to cancel');
      expect(wait.declined, isFalse);

      // Released: the mirror is gone.
      sync.report('later');
      expect(statuses.length, 2);
    },
  );

  test('joins a download already in flight and leaves it running', () async {
    final sync = _FakeSync(isSyncing: true);
    final wait = MasterGamesWait();

    final parked = wait.park(sync, onStatus: (_) {});
    await _settle();
    expect(sync.syncCalls, 0, reason: 'joined, not duplicated');

    wait.stopWaiting();
    await parked;
    expect(sync.cancelCalls, 0, reason: 'not ours to cancel');
  });

  test('the download finishing releases the wait by itself', () async {
    final sync = _FakeSync();
    final wait = MasterGamesWait();

    final parked = wait.park(sync, onStatus: (_) {});
    await _settle();
    sync.done.complete();
    await parked;

    expect(wait.isWaiting, isFalse);
    expect(sync.cancelCalls, 0);
  });

  test('decline releases the wait and is remembered for the session', () async {
    final sync = _FakeSync();
    final wait = MasterGamesWait();

    final parked = wait.park(sync, onStatus: (_) {});
    await _settle();
    wait.decline();
    await parked;

    expect(wait.declined, isTrue);
    expect(sync.cancelCalls, 1);
  });

  test('a failed download is not an error for the run', () async {
    final sync = _FakeSync()..failWith = StateError('offline');
    final wait = MasterGamesWait();

    await wait.park(sync, onStatus: (_) {});

    expect(wait.isWaiting, isFalse);
  });

  test('releasing an idle wait is a no-op', () {
    final wait = MasterGamesWait();
    wait.stopWaiting();
    wait.decline();
    expect(wait.declined, isTrue);
    expect(wait.isWaiting, isFalse);
  });
}

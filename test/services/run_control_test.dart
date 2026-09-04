/// [RunControl] on its own — the cooperative pause/cancel three long-running
/// services share.
///
/// The case worth pinning is the one the hand-written copies each had to
/// remember: a cancel that arrives *while the run is paused* must end it.
/// Miss the re-check and the loop waits forever on a Resume that is never
/// coming, with the user having already pressed Stop.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/services/run_control.dart';

void main() {
  test('a fresh control lets work proceed', () async {
    final control = RunControl();
    expect(control.isPaused, isFalse);
    expect(control.isCancelled, isFalse);
    expect(await control.checkpoint(), isTrue);
  });

  test('cancelling stops the run at the next checkpoint', () async {
    final control = RunControl()..cancel();
    expect(control.isCancelled, isTrue);
    expect(await control.checkpoint(), isFalse);
  });

  test('a paused checkpoint waits, then continues on resume', () async {
    final control = RunControl()..pause();
    var resumed = false;

    final pending = control.checkpoint();
    // Nothing should have completed yet: give the poll loop a few turns.
    await Future<void>.delayed(RunControl.pollInterval * 2);
    expect(resumed, isFalse);

    resumed = true;
    control.resume();
    expect(await pending, isTrue, reason: 'the run carries on after Resume');
  });

  test('cancelling a paused run ends it instead of hanging', () async {
    final control = RunControl()..pause();
    final pending = control.checkpoint();

    await Future<void>.delayed(RunControl.pollInterval * 2);
    control.cancel();

    expect(
      await pending.timeout(const Duration(seconds: 2)),
      isFalse,
      reason: 'Stop must beat a pause that nobody is going to resume',
    );
  });

  test('reset clears both flags so the next run starts clean', () async {
    final control = RunControl()
      ..pause()
      ..cancel();
    control.reset();
    expect(control.isPaused, isFalse);
    expect(control.isCancelled, isFalse);
    expect(await control.checkpoint(), isTrue);
  });

  test('a cancelled run stays cancelled until it is reset', () {
    // Deliberate: the owner asks a cancelled run for its partial results
    // afterwards, and clearing the flag on the way out would make it lie
    // about why it stopped.
    final control = RunControl()..cancel();
    control.resume();
    expect(control.isCancelled, isTrue);
  });
}

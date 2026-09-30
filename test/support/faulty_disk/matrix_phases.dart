// The phases of a fault matrix case, each in an isolate of its own, as a
// process would be: the stores are built there, inside a FaultyDisk run, and
// only sendable values come back — the trace, how the run ended, and what
// was answered, already projected to verdicts and strings.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import '../profile/profile.dart';
import '../profile/profile_snapshot.dart';
import 'contracts.dart';
import 'fault_plan.dart';
import 'faulty_disk.dart';
import 'io_trace.dart';
import 'scenario.dart';

/// Longer than any clean phase takes; a phase still running then has hung.
const _limit = Duration(seconds: 20);

enum Ended { returned, threw, crashed, hung }

/// What a phase answered, when it ran to the end.
final class Answers {
  const Answers({
    this.verdict,
    this.retried,
    this.read,
    this.probes = const {},
    this.accessed,
    this.faulted,
  });

  /// What the command answered, and its retry when there was one.
  final Verdict? verdict;
  final Verdict? retried;

  /// The scenario's first read, and each probe by name.
  final String? read;
  final Map<String, String> probes;

  /// The profile after the first access that followed the command in the
  /// same session, before any retry.
  final ProfileSnapshot? accessed;

  /// In a recovery phase, what the read that met the fault answered.
  final String? faulted;
}

final class Phase {
  const Phase(this.trace, this.ended, this.detail, [this.answers]);

  final List<IoOp> trace;
  final Ended ended;

  /// The result's type, the error, or the effect a crash or hang stopped at.
  final String detail;
  final Answers? answers;
}

/// Only the stores built: the effects their constructors make, which every
/// other phase starts with. Those belong to the app starting, not to the
/// command, so no fault is planted in them.
Future<Phase> openPhase<S, R>(
  StorageScenario<S, R> scenario,
  Profile profile,
) => Isolate.run(
  () => _onDisk(profile, const FaultPlan.none(), () async {
    scenario.open(profile);
    return ('opened', const Answers());
  }),
);

/// The command under [plan], with nothing after it: a crash ends a
/// process, and the reopen is another phase.
Future<Phase> commandPhase<S, R>(
  StorageScenario<S, R> scenario,
  Profile profile,
  FaultPlan plan,
) => Isolate.run(
  () => _onDisk(profile, plan, () async {
    final result = await scenario.command(scenario.open(profile));
    return (
      '${result.runtimeType}',
      Answers(verdict: scenario.verdict(result)),
    );
  }),
);

/// A restart: the first read, and with [probes] each probe after it.
Future<Phase> reopenPhase<S, R>(
  StorageScenario<S, R> scenario,
  Profile profile, {
  bool probes = false,
  FaultPlan plan = const FaultPlan.none(),
}) => Isolate.run(
  () => _onDisk(profile, plan, () async {
    final stores = scenario.open(profile);
    final read = await _answer(() => scenario.firstRead(stores));
    final answers = <String, String>{};
    for (final probe in probes ? scenario.probes : <Probe<S>>[]) {
      answers[probe.name] = await _answer(() => probe.read(stores));
    }
    return ('read $read', Answers(read: read, probes: answers));
  }),
);

/// One session: the command under [plan], then the next access, then for
/// an unknown answer the same operation again.
Future<Phase> sessionPhase<S, R>(
  StorageScenario<S, R> scenario,
  Profile profile,
  FaultPlan plan,
) => Isolate.run(
  () => _onDisk(profile, plan, () async {
    final stores = scenario.open(profile);
    final result = await scenario.command(stores);
    final verdict = scenario.verdict(result);
    final read = await _answer(() => scenario.firstRead(stores));
    final accessed = ProfileSnapshot.of(profile);
    final retry = scenario.retry;
    final retried = verdict == Verdict.unknown && retry != null
        ? scenario.verdict(await retry(stores))
        : null;
    return (
      '${result.runtimeType}',
      Answers(
        verdict: verdict,
        retried: retried,
        read: read,
        accessed: accessed,
      ),
    );
  }),
);

/// A restart whose first access meets [plan]'s fault, then a second access
/// in the same session once it has cleared; both answers come back.
Future<Phase> recoveryPhase<S, R>(
  StorageScenario<S, R> scenario,
  Profile profile,
  FaultPlan plan,
) => Isolate.run(
  () => _onDisk(profile, plan, () async {
    final stores = scenario.open(profile);
    final first = await _answer(() => scenario.firstRead(stores));
    final read = await _answer(() => scenario.firstRead(stores));
    return ('first read $first', Answers(read: read, faulted: first));
  }),
);

/// [body] on a FaultyDisk over [profile], with the log's console lines
/// kept out of the test output.
Future<Phase> _onDisk(
  Profile profile,
  FaultPlan plan,
  Future<(String, Answers)> Function() body,
) async {
  final run = await runZoned(
    () => FaultyDisk(Directory(profile.root)).run(plan, body, limit: _limit),
    zoneSpecification: ZoneSpecification(print: (_, _, _, _) {}),
  );
  return switch (run.end) {
    Returned(value: (final detail, final answers)) => Phase(
      run.trace,
      Ended.returned,
      detail,
      answers,
    ),
    Threw(:final error) => Phase(run.trace, Ended.threw, '$error'),
    Crashed(:final at) => Phase(run.trace, Ended.crashed, '$at'),
    Hung(:final at) => Phase(run.trace, Ended.hung, '$at'),
  };
}

/// What [read] answered, or what it threw: a read that throws is an answer
/// the contracts compare like any other.
Future<String> _answer(Future<String> Function() read) async {
  try {
    return await read();
  } on Object catch (error) {
    return 'threw $error';
  }
}

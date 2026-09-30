// Two commands of one session against each other: the held one paused at
// each change it makes while the other runs, then let go. Whatever the
// interleaving, the profile must end as one of the two serial orders
// leaves it, and each command must answer as it does in that order. When
// the second waits on a lock the first holds, it is let go once the second
// has had time to get past it; that case is then the first order and is
// still checked as one.
//
// Each case runs in an isolate of its own, as the fault matrix's phases do.
// A quick run pauses at each change the held command makes and at each read
// before its first one; `CAP_FAULT_DEPTH=full` pauses at every read too.
// `CAP_FAULT_ONLY=<name>/<key>` runs the cases under that prefix alone and
// prints them. A failing test prints which order each case matched.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:collection/collection.dart';
import 'package:flutter_test/flutter_test.dart';

import '../profile/profile.dart';
import '../profile/profile_snapshot.dart';
import '../profile/profile_workspace.dart';
import 'contracts.dart';
import 'fault_plan.dart';
import 'faulty_disk.dart';
import 'io_trace.dart';
import 'ledger.dart';

final class Interleaving<S> {
  const Interleaving({
    required this.name,
    required this.seed,
    required this.open,
    required this.held,
    required this.meanwhile,
    required this.read,
    this.prepare,
    this.seesHeld = false,
    this.known = const {},
  });

  final String name;
  final Future<void> Function(Profile profile) seed;

  /// The stores and owners of one session, built inside the run.
  final S Function(Profile profile) open;

  /// What the session did before either command: loading an owner, or the
  /// read a command's inputs came from. Never paused.
  final Future<void> Function(S session)? prepare;

  /// The command paused at each effect, and the one run meanwhile; each
  /// answers what it answered, projected to a string.
  final Future<String> Function(S session) held;
  final Future<String> Function(S session) meanwhile;

  /// What the session reads once both are done.
  final Future<String> Function(S session) read;

  /// Whether [meanwhile] must see [held], which was accepted before it
  /// began: it must answer as it does after it.
  final bool seesHeld;

  /// Violations confirmed as findings, by `<key>/<contract>`.
  final Map<String, String> known;
}

/// How long the second command may take before it counts as waiting for
/// the first: far longer than a clean run of it takes.
const _waiting = Duration(milliseconds: 300);

/// What one run left, sendable.
final class _Ran {
  const _Ran(
    this.trace,
    this.ended, [
    this.answers = const [],
    this.waited = false,
  ]);
  final List<IoOp> trace;
  final String ended;

  /// The held command's answer, the other's, and the read after both.
  final List<String> answers;

  /// Whether the other command was still running when the held one was
  /// let go: it waited for it, on a lock say.
  final bool waited;
}

enum _Order { heldFirst, meanwhileFirst, prepared, heldAlone }

/// Registers [spec] as one test.
void interleavings<S>(Interleaving<S> spec) {
  final env = Platform.environment;
  final full = const {'full', 'exhaustive'}.contains(env['CAP_FAULT_DEPTH']);
  final only = env['CAP_FAULT_ONLY'];
  late ProfileWorkspace workspace;
  setUpAll(() async => workspace = await ProfileWorkspace.seeded(spec.seed));
  tearDownAll(() => workspace.dispose());
  test(spec.name, () async {
    Future<(_Ran, Map<String, String>)> serial(_Order order) async {
      final profile = await workspace.fresh();
      final ran = await Isolate.run(() => _serial(spec, profile, order));
      return (ran, ProfileSnapshot.of(profile).projection);
    }

    final (prepared, _) = await serial(_Order.prepared);
    final (alone, _) = await serial(_Order.heldAlone);
    final orders = [
      await serial(_Order.heldFirst),
      await serial(_Order.meanwhileFirst),
    ];
    for (final (ran, _) in orders) {
      if (ran.answers.isEmpty) throw StateError('${spec.name}: ${ran.ended}');
    }
    final found = <Violation>[];
    final held = alone.trace.skip(prepared.trace.length).toList();
    // Before its first change the held command has been accepted and may
    // not hold a lock yet: every read there is a point to pause at.
    final firstChange = held.indexWhere((op) => !op.kind.reads);
    for (final (i, op) in held.indexed) {
      final at = '${op.key}';
      if (!full && op.kind.reads && i > firstChange) continue;
      if (only != null && !'${spec.name}/$at'.startsWith(only)) continue;
      final profile = await workspace.fresh();
      final ran = await Isolate.run(() => _paused(spec, profile, op.key));
      if (only != null) _print(at, ran);
      if (ran.ended == 'unpaused') continue;
      final state = ProfileSnapshot.of(profile).projection;
      final (order, violations) = _serialisable(
        at,
        ran,
        state,
        orders,
        seesHeld: spec.seesHeld,
      );
      printOnFailure('$at: $order${ran.waited ? ', after waiting' : ''}');
      found.addAll(violations);
    }
    checkLedger(
      spec.name,
      found,
      spec.known,
      replay: (v) => "CAP_FAULT_ONLY='${spec.name}/${v.at}'",
      partial: only != null,
    );
  });
}

/// Whether the interleaved [ran], which left [state], is one of [orders]:
/// the held command first, then the other. With [seesHeld] the other must
/// answer as it does after the held one. Also answers which order it was,
/// for the record: either, when both leave the same.
(String, List<Violation>) _serialisable(
  String at,
  _Ran ran,
  Map<String, String> state,
  List<(_Ran, Map<String, String>)> orders, {
  required bool seesHeld,
}) {
  if (ran.answers.isEmpty) {
    return ('none', [Violation('O5', at, 'did not finish: ${ran.ended}')]);
  }
  bool same(Map<String, String> a) =>
      a.length == state.length &&
      a.entries.every((e) => state[e.key] == e.value);
  final landed = [
    for (final (order, projection) in orders)
      if (same(projection) && _sameAnswers(order.answers, ran.answers)) order,
  ];
  final (heldFirst, _) = orders.first;
  final order = switch (landed.length) {
    2 => 'either order',
    1 => identical(landed.single, heldFirst) ? 'held first' : 'held last',
    _ => 'neither order',
  };
  final left = [
    for (final (order, projection) in orders)
      if (same(projection)) order,
  ];
  return (
    order,
    [
      if (left.isEmpty)
        Violation(
          'I1',
          at,
          'left neither serial order; against the held command first:\n'
              '${projectionDiff(orders.first.$2, state)}',
        )
      else if (landed.isEmpty)
        Violation(
          'I2',
          at,
          'answered ${ran.answers}, as in neither order: '
              '${[for (final order in left) order.answers]}',
        ),
      if (seesHeld && ran.answers[1] != heldFirst.answers[1])
        Violation(
          'I3',
          at,
          'did not see the held command: ${ran.answers[1]}, '
              'not ${heldFirst.answers[1]}',
        ),
    ],
  );
}

bool _sameAnswers(List<String> a, List<String> b) =>
    const ListEquality<String>().equals(a, b);

/// Both commands one after the other in [order], or only as far as
/// [_Order.prepared] or the held command alone, for their effects.
Future<_Ran> _serial<S>(Interleaving<S> spec, Profile profile, _Order order) =>
    _onDisk(profile, const FaultPlan.none(), () async {
      final session = spec.open(profile);
      await spec.prepare?.call(session);
      if (order == _Order.prepared) return (const <String>[], false);
      if (order == _Order.heldAlone) {
        return ([await _answer(spec.held, session)], false);
      }
      final String held;
      final String meanwhile;
      if (order == _Order.heldFirst) {
        held = await _answer(spec.held, session);
        meanwhile = await _answer(spec.meanwhile, session);
      } else {
        meanwhile = await _answer(spec.meanwhile, session);
        held = await _answer(spec.held, session);
      }
      return ([held, meanwhile, await _answer(spec.read, session)], false);
    });

/// The held command paused at [key] while the other runs, let go once the
/// other finished or has waited [_waiting] for it.
Future<_Ran> _paused<S>(Interleaving<S> spec, Profile profile, OpKey key) {
  final pause = Pause();
  return _onDisk(profile, FaultPlan.at(key, pause), () async {
    final session = spec.open(profile);
    await spec.prepare?.call(session);
    final held = _answer(spec.held, session);
    // A command that finished first never reached the pause: the effect
    // is synchronous, which cannot wait, or not the command's this time.
    if (!await Future.any([
      pause.reached.then((_) => true),
      held.then((_) => false),
    ])) {
      return (const <String>[], false);
    }
    final meanwhile = _answer(spec.meanwhile, session);
    final waited = await Future.any([
      meanwhile.then((_) => false),
      Future<bool>.delayed(_waiting, () => true),
    ]);
    pause.release();
    return (
      [await held, await meanwhile, await _answer(spec.read, session)],
      waited,
    );
  });
}

Future<_Ran> _onDisk(
  Profile profile,
  FaultPlan plan,
  Future<(List<String>, bool)> Function() body,
) async {
  final run = await runZoned(
    () => FaultyDisk(Directory(profile.root)).run(plan, body),
    zoneSpecification: ZoneSpecification(print: (_, _, _, _) {}),
  );
  return switch (run.end) {
    Returned(value: (final answers, _)) when answers.isEmpty => _Ran(
      run.trace,
      'unpaused',
    ),
    Returned(value: (final answers, final waited)) => _Ran(
      run.trace,
      'returned',
      answers,
      waited,
    ),
    Threw(:final error) => _Ran(run.trace, 'threw $error'),
    Crashed(:final at) => _Ran(run.trace, 'crashed at $at'),
    Hung(:final at) => _Ran(run.trace, 'hung at $at'),
  };
}

/// What [command] answered, or what it threw.
Future<String> _answer<S>(
  Future<String> Function(S session) command,
  S session,
) async {
  try {
    return await command(session);
  } on Object catch (error) {
    return 'threw $error';
  }
}

void _print(String at, _Ran ran) {
  // ignore: avoid_print
  print(
    '$at: ${ran.ended} ${ran.answers}${ran.waited ? ' (waited)' : ''}\n'
    '${[for (final op in ran.trace) '  ${op.key}'].join('\n')}',
  );
}

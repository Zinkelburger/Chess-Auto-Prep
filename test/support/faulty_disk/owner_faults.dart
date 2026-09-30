// An owner the app wires (the Books, a trainer's progress, a search) driven
// as the user drives it, with one fault planted at each effect its commands
// make: an I/O error, or the answer to a change lost. What the storage
// matrix checks of a store, this checks of the owner above it: its
// PendingWrites reports a problem exactly when an accepted write is not on
// disk, and the retry the app then offers clears it with the write landed
// once. The fault matrix's crash families are the stores' concern: a kill
// takes the owner with it.
//
// Each case runs in an isolate of its own, as the matrix's phases do, so
// statics and lock queues start empty. Owners are built with no save delay
// and run on real async: real IO and isolates never finish under a fake
// clock. `CAP_FAULT_ONLY=<sequence>/<case>` runs the cases under that
// prefix alone and prints their traces.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:chess_auto_prep/storage/pending_writes.dart';
import 'package:flutter_test/flutter_test.dart';

import '../profile/profile.dart';
import '../profile/profile_workspace.dart';
import 'contracts.dart';
import 'fault_plan.dart';
import 'faulty_disk.dart';
import 'io_trace.dart';
import 'ledger.dart';

final class OwnerSequence<S> {
  const OwnerSequence({
    required this.name,
    required this.seed,
    required this.open,
    required this.run,
    required this.pending,
    required this.retry,
    required this.landed,
    this.prepare,
    this.sameAnswer = false,
    this.known = const {},
  });

  final String name;

  /// Fills an empty profile, with plain dart:io; runs once.
  final Future<void> Function(Profile profile) seed;

  /// The stores and the owner with its PendingWrites, built inside the run.
  final S Function(Profile profile) open;

  /// What the app did before the user acted, such as loading the owner;
  /// no fault is planted in its effects.
  final Future<void> Function(S owner)? prepare;

  /// The user's commands; answers what the owner shows afterwards.
  final Future<String> Function(S owner) run;

  final PendingWrites Function(S owner) pending;

  /// What the app offers once a problem is reported.
  final Future<void> Function(S owner) retry;

  /// What of the commands is on disk, read around the trace by stores of
  /// its own, as the next start would: equal to the clean run's exactly
  /// when all of them landed, once.
  final Future<String> Function(Profile profile) landed;

  /// Whether every case must answer as the clean run did: a failed write of
  /// derived data never fails the command (O10).
  final bool sameAnswer;

  /// Violations confirmed as findings, by `<family>/<key>/<contract>`.
  final Map<String, String> known;
}

/// What one run of a sequence left: sendable, so it comes back from the
/// isolate the run was made in.
final class _End {
  const _End(
    this.trace,
    this.ended, {
    this.answer,
    this.problem,
    this.landed,
    this.retriedProblem,
    this.retriedLanded,
  });

  final List<IoOp> trace;
  final String ended;
  final String? answer;
  final String? problem;
  final String? landed;

  /// After the retry, when a problem was reported.
  final String? retriedProblem;
  final String? retriedLanded;
}

/// Registers [sequence] as tests: the clean run, then a transient error at
/// each effect of its commands and a lost answer at each change.
void ownerFaults<S>(OwnerSequence<S> sequence) {
  final only = Platform.environment['CAP_FAULT_ONLY'];
  late ProfileWorkspace workspace;
  late _End clean;
  late int setup;
  setUpAll(() async {
    workspace = await ProfileWorkspace.seeded(sequence.seed);
    final profile = workspace.live;
    setup = (await _inIsolate(
      sequence,
      profile,
      prepareOnly: true,
    )).trace.length;
    clean = await _inIsolate(sequence, await workspace.fresh());
    if (clean.problem != null || clean.answer == null) {
      throw StateError('${sequence.name} did not run clean: ${clean.ended}');
    }
  });
  tearDownAll(() => workspace.dispose());
  Iterable<IoOp> commands() => clean.trace.skip(setup);
  Future<void> family(String name, Fault fault, bool Function(IoOp) where) =>
      _family(
        sequence,
        workspace,
        clean,
        name,
        fault,
        commands().where(where),
        only,
      );
  group(sequence.name, () {
    test('transient', () => family('transient', _eio, (_) => true));
    test('lostAck', () => family('lostAck', _lost, (op) => !op.kind.reads));
  });
}

const _eio = FailBefore(IoError.eio);
const _lost = FailAfter(IoError.eio);

Future<void> _family<S>(
  OwnerSequence<S> sequence,
  ProfileWorkspace workspace,
  _End clean,
  String family,
  Fault fault,
  Iterable<IoOp> ops,
  String? only,
) async {
  final found = <Violation>[];
  for (final op in ops) {
    final at = '$family/${op.key}';
    if (only != null && !'${sequence.name}/$at'.startsWith(only)) continue;
    final end = await _inIsolate(
      sequence,
      await workspace.fresh(),
      plan: FaultPlan.at(op.key, fault),
    );
    if (only != null) _print(at, end);
    found.addAll(_honest(sequence, clean, at, op, fault, end));
  }
  checkLedger(
    sequence.name,
    found,
    {
      for (final MapEntry(:key, :value) in sequence.known.entries)
        if (key.startsWith('$family/')) key: value,
    },
    replay: (v) => "CAP_FAULT_ONLY='${sequence.name}/${v.at}'",
    partial: only != null,
  );
}

/// The PendingWrites contract on one case, against the [clean] run:
///
/// - PW1: nothing is reported, but not everything landed;
/// - PW2: a failed read is reported though everything landed: a false alarm
///   (a lost answer to a change may be reported: the owner cannot know);
/// - PW3: after the retry a problem is still reported;
/// - PW4: after the retry the disk is not as the clean run left it: a
///   change missing, or made twice.
List<Violation> _honest<S>(
  OwnerSequence<S> sequence,
  _End clean,
  String at,
  IoOp op,
  Fault fault,
  _End end,
) {
  final after = clean.landed;
  final problem = end.problem;
  if (end.answer == null) {
    return [Violation('O2', at, 'did not answer: ${end.ended}')];
  }
  return [
    if (sequence.sameAnswer && end.answer != clean.answer)
      Violation('O10', at, 'answered ${end.answer}, not ${clean.answer}'),
    if (problem == null && end.landed != after)
      Violation('PW1', at, 'no problem reported, but on disk: ${end.landed}'),
    if (problem != null &&
        end.landed == after &&
        fault is FailBefore &&
        op.kind.reads)
      Violation('PW2', at, 'a false alarm, with everything on disk: $problem'),
    if (problem != null && end.retriedProblem != null)
      Violation('PW3', at, 'the retry still reports ${end.retriedProblem}'),
    if (problem != null && end.retriedLanded != after)
      Violation('PW4', at, 'after the retry, on disk: ${end.retriedLanded}'),
  ];
}

Future<_End> _inIsolate<S>(
  OwnerSequence<S> sequence,
  Profile profile, {
  FaultPlan plan = const FaultPlan.none(),
  bool prepareOnly = false,
}) => Isolate.run(() => _session(sequence, profile, plan, prepareOnly));

/// One session on a FaultyDisk: the owner opened and prepared, the commands
/// under [plan], what PendingWrites then reports and what landed, and for a
/// reported problem the retry and both again. The disk is read around the
/// trace, by stores of its own, so what it holds is not faulted.
Future<_End> _session<S>(
  OwnerSequence<S> sequence,
  Profile profile,
  FaultPlan plan,
  bool prepareOnly,
) async {
  Future<String> landed() => Zone.root.run(() => sequence.landed(profile));
  final run = await runZoned(
    () => FaultyDisk(Directory(profile.root)).run(plan, () async {
      final owner = sequence.open(profile);
      await sequence.prepare?.call(owner);
      if (prepareOnly) return const _End([], 'prepared');
      final answer = await sequence.run(owner);
      final pending = sequence.pending(owner);
      final problem = await pending.settle();
      final first = await landed();
      if (problem == null) {
        return _End(const [], 'returned', answer: answer, landed: first);
      }
      await sequence.retry(owner);
      return _End(
        const [],
        'returned',
        answer: answer,
        problem: problem,
        landed: first,
        retriedProblem: await pending.settle(),
        retriedLanded: await landed(),
      );
    }),
    zoneSpecification: ZoneSpecification(print: (_, _, _, _) {}),
  );
  return switch (run.end) {
    Returned(:final value) => _End(
      run.trace,
      value.ended,
      answer: value.answer,
      problem: value.problem,
      landed: value.landed,
      retriedProblem: value.retriedProblem,
      retriedLanded: value.retriedLanded,
    ),
    Threw(:final error) => _End(run.trace, 'threw $error'),
    Crashed(:final at) => _End(run.trace, 'crashed at $at'),
    Hung(:final at) => _End(run.trace, 'hung at $at'),
  };
}

void _print(String at, _End end) {
  // ignore: avoid_print
  print(
    '$at: ${end.ended}; answered ${end.answer}; problem ${end.problem}; '
    'landed ${end.landed}; retried ${end.retriedProblem} '
    '${end.retriedLanded}\n'
    '${[for (final op in end.trace) '  ${op.key}'].join('\n')}',
  );
}

// The fault matrix: one storage scenario run once cleanly to record every
// effect it makes, then again once per effect with a fault planted there,
// and the data contracts (contracts.dart) checked on what each run leaves.
// The effects come from the recorded trace, so no scenario names a step and
// a step added to a store is covered without anyone adding it.
//
// A kill loses memory, so a command runs in one isolate and the reopen in a
// fresh one: statics, the recovery gate's flags and the lock queue start
// empty, as after a restart. The transient and lost-acknowledgement
// families keep one isolate, since their contract is that the same session
// finishes the work. Crash states of one family that are byte for byte the
// same (either side of a flush, say) share one reopen.
//
// Every violation is reported with a replay line and what the profile held;
// `CAP_FAULT_ONLY=<scenario>/<case>` runs the cases under that prefix alone
// and prints their traces, every recovery fault under it included.
// `CAP_FAULT_DEPTH=full` (or `exhaustive`) runs every fault planted inside
// a recovery (transient, briefly missing, a second kill) instead of a
// sample of each, for a nightly or on-demand run; `CAP_FAULT_SEED` picks
// the sample.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import '../profile/authority.dart';
import '../profile/profile.dart';
import '../profile/profile_integrity.dart';
import '../profile/profile_snapshot.dart';
import '../profile/profile_workspace.dart';
import 'contracts.dart';
import 'fault_plan.dart';
import 'faulty_disk.dart';
import 'io_trace.dart';
import 'ledger.dart';
import 'matrix_phases.dart';
import 'perturbations.dart';
import 'scenario.dart';

/// How far the matrix goes, from the environment.
final class MatrixOptions {
  const MatrixOptions({this.exhaustive = false, this.seed = 1, this.only});

  factory MatrixOptions.fromEnvironment([Map<String, String>? environment]) {
    final env = environment ?? Platform.environment;
    return MatrixOptions(
      exhaustive: const {'full', 'exhaustive'}.contains(env['CAP_FAULT_DEPTH']),
      seed: int.tryParse(env['CAP_FAULT_SEED'] ?? '') ?? 1,
      only: env['CAP_FAULT_ONLY'],
    );
  }

  /// Every recovery fault, rather than [_sampled] of them.
  final bool exhaustive;
  final int seed;

  /// `<scenario>/<case>`, or a prefix of one: only those cases run.
  final String? only;
}

/// How many faults inside a recovery a quick run tries, per family.
const _sampled = 24;

const _familyLimit = Timeout(Duration(minutes: 10));

/// The kills planted at each effect, by the name a case key gives them.
const _crashFaults = [('before', CrashBefore()), ('after', CrashAfter())];

/// Registers [scenario]'s families as tests: `record` for the clean run's
/// trace, then one test per family, each failing on a violation the
/// scenario's ledger does not name or on a ledger entry that no longer
/// shows.
void faultMatrix<S, R>(
  StorageScenario<S, R> scenario, {
  Set<Family>? families,
  MatrixOptions? options,
}) {
  final matrix = _Matrix(scenario, options ?? MatrixOptions.fromEnvironment());
  setUpAll(matrix.prepare);
  tearDownAll(matrix.dispose);
  group(scenario.name, () {
    test('record', () => matrix.check('record', matrix.record));
    for (final family in families ?? scenario.families) {
      test(
        family.name,
        () => matrix.check(family.name, () => matrix.run(family)),
        // A full run tries every fault inside every recovery: no limit.
        timeout: matrix.options.exhaustive ? Timeout.none : _familyLimit,
      );
    }
  });
}

/// The clean run: its trace and the profile either side of it, with what
/// the first read and the probes answered on each.
final class _Recording {
  _Recording({
    required this.trace,
    required this.setup,
    required this.before,
    required this.after,
    required this.untraced,
    required this.onBefore,
    required this.onAfter,
  });

  final List<IoOp> trace;

  /// How many effects of [trace] building the stores made.
  final int setup;
  final ProfileSnapshot before;
  final ProfileSnapshot after;
  final List<String> untraced;
  final Answers onBefore;
  final Answers onAfter;

  late final beforeIntegrity = ProfileIntegrity.of(before);
  late final afterIntegrity = ProfileIntegrity.of(after);

  /// The command's own effects, where the families plant their faults.
  Iterable<IoOp> get command => trace.skip(setup);

  Iterable<IoOp> get mutating => command.where((op) => !op.kind.reads);
}

/// A reopened crash state, shared by every crash that left the same bytes.
final class _Reopened {
  _Reopened(this.at, this.first, this.second, this.reopened, this.again);

  /// The first case that reached it; its violations are reported there.
  final String at;

  /// The first read after the restart, then the probes after another one.
  final Phase first;
  final Phase second;

  /// After the first access, and after the second restart's.
  final ProfileSnapshot reopened;
  final ProfileSnapshot again;
}

final class _CrashCase {
  _CrashCase(
    this.at,
    this.key,
    this.fault,
    this.crashed,
    this.state, {
    required this.problems,
  });
  final String at;
  final OpKey key;
  final Fault fault;
  final ProfileSnapshot crashed;
  final _Reopened state;

  /// How the command ran: a hang, or a run that did not stop at the crash.
  final List<Violation> problems;

  bool get firstOfState => state.at == at;
}

final class _Matrix<S, R> {
  _Matrix(this.scenario, this.options);

  final StorageScenario<S, R> scenario;
  final MatrixOptions options;
  late final ProfileWorkspace _workspace;
  late final _Recording _recording;
  final _states = <String, _Reopened>{};
  final _crashes = <String, _CrashCase>{};
  final _ran = <String>{};
  final _sampledFamilies = <String>{};
  final _shown = <String, String>{};

  Future<void> prepare() async {
    _workspace = await ProfileWorkspace.seeded(scenario.seed);
    _recording = await _record();
  }

  Future<void> dispose() => _workspace.dispose();

  bool _selected(String at) {
    final only = options.only;
    return only == null || '${scenario.name}/$at'.startsWith(only);
  }

  /// Whether some case under [prefix] may be selected.
  bool _mayRun(String prefix) {
    final only = options.only;
    final named = '${scenario.name}/$prefix';
    return only == null || named.startsWith(only) || only.startsWith(named);
  }

  Future<_Recording> _record() async {
    final onBefore = await reopenPhase(
      scenario,
      await _workspace.fresh(),
      probes: true,
    );
    final profile = await _workspace.fresh();
    final setup = await openPhase(scenario, profile);
    final before = ProfileSnapshot.of(profile);
    final disk = FaultyDisk(Directory(profile.root));
    final plain = disk.snapshot();
    final run = await commandPhase(scenario, profile, const FaultPlan.none());
    if (run.answers?.verdict != Verdict.committed) {
      throw StateError('${scenario.name} did not commit: ${run.detail}');
    }
    final after = ProfileSnapshot.of(profile);
    final untraced = untracedWrites(
      plain,
      disk.snapshot(),
      run.trace,
      unmanaged: sqliteManaged,
    );
    final onAfter = await reopenPhase(scenario, profile, probes: true);
    _verbose('record', run);
    return _Recording(
      trace: run.trace,
      setup: setup.trace.length,
      before: before,
      after: after,
      untraced: untraced,
      onBefore: onBefore.answers!,
      onAfter: onAfter.answers!,
    );
  }

  /// The save discipline lints on the clean trace, and every change it made
  /// accounted for by a traced effect.
  Future<List<Violation>> record() async {
    final trace = _recording.trace;
    _ran.addAll([
      for (final op in trace)
        if (_selected('record/${op.key}')) 'record/${op.key}',
    ]);
    // Named as the trace's keys name them.
    final keyed = {
      for (final op in trace) ...{
        relativeName(_workspace.live.root, op.path): op.key.path,
        if (op.to case final to?)
          relativeName(_workspace.live.root, to): op.key.to!,
      },
    };
    final existing = {
      for (final name in _recording.before.entries.keys) keyed[name] ?? name,
    };
    return [
      for (final name in _recording.untraced)
        Violation('trace', 'record/$name', 'changed by no traced effect'),
      ...syncedBeforePublish(trace),
      ...directoriesSynced(trace, committed: true, existing: existing),
      ...journalFirst(trace, existing: existing),
      ...noInPlaceWrites(trace),
      ...noReadBack(trace),
    ].where((v) => _selected(v.at)).toList();
  }

  Future<List<Violation>> run(Family family) => switch (family) {
    Family.crash => _crashFamily(),
    Family.crashMidway => _midwayFamily(),
    Family.transient => _inSession(
      'transient',
      const FailBefore(IoError.eio),
      _recording.command,
    ),
    Family.lostAck => _inSession(
      'lostAck',
      const FailAfter(IoError.eio),
      _recording.mutating,
    ),
    Family.recoveryFault => _recoveryFamily(),
    Family.recoveryMissing => _missingFamily(),
    Family.recoveryCrash => _secondCrashFamily(),
    Family.perturbed => _perturbedFamily(),
  };

  // Crashes.

  Future<List<Violation>> _crashFamily() async {
    final cases = <_CrashCase>[];
    for (final op in _recording.mutating) {
      for (final (name, fault) in _crashFaults) {
        final at = 'crash/$name/${op.key}';
        if (_selected(at)) cases.add(await _crash(at, op.key, fault));
      }
    }
    final (before, after) = (_recording.before, _recording.after);
    return [
      for (final c in cases) ...c.problems,
      for (final c in cases)
        if (c.firstOfState) ..._afterCrash(c.state),
      ...verdictsHold(
        before: before,
        after: after,
        crashes: [for (final c in cases) (c.at, c.state.reopened)],
      ),
    ];
  }

  Future<List<Violation>> _midwayFamily() async {
    final violations = <Violation>[];
    for (final op in _recording.mutating) {
      final at = 'crashMidway/${op.key}';
      if (!_hasMidway(op) || !_selected(at)) continue;
      final c = await _crash(at, op.key, const CrashMidway());
      violations.addAll(c.problems);
      if (c.firstOfState) violations.addAll(_afterCrash(c.state));
    }
    return violations;
  }

  /// Only a write, an exclusive publish (POSIX) and a recursive mkdir have
  /// a state half way through; a mkdir with nothing missing crashes before.
  bool _hasMidway(IoOp op) => switch (op.kind) {
    IoKind.write || IoKind.mkdir => true,
    IoKind.publishNew => !Platform.isWindows,
    _ => false,
  };

  /// The command killed by [fault] at [key], then reopened: memoised, since
  /// the recovery and perturbed families start from the same states.
  Future<_CrashCase> _crash(String at, OpKey key, Fault fault) async {
    final known = _crashes[at];
    if (known != null) return known;
    _ran.add(at);
    final profile = await _workspace.fresh();
    final phase = await commandPhase(
      scenario,
      profile,
      FaultPlan.at(key, fault),
    );
    _verbose(at, phase);
    final crashed = ProfileSnapshot.of(profile);
    final state = await _reopen(at, profile, crashed);
    _show(at, state.reopened);
    return _crashes[at] = _CrashCase(
      at,
      key,
      fault,
      crashed,
      state,
      problems: [
        ..._ended(at, phase, key, crash: true),
        if (phase.ended == Ended.returned || phase.ended == Ended.threw)
          // A mkdir that is not recursive has no midway state to crash in.
          if (fault is! CrashMidway || key.kind != IoKind.mkdir)
            Violation('D', at, 'ran past its crash: ${phase.detail}'),
      ],
    );
  }

  Future<_Reopened> _reopen(
    String at,
    Profile profile,
    ProfileSnapshot crashed,
  ) async {
    // Per family, so a state two families reach reports under each.
    final key = '${at.split('/').first}\n${_stateKey(crashed)}';
    final shared = _states[key];
    if (shared != null) return shared;
    final first = await reopenPhase(scenario, profile);
    final reopened = ProfileSnapshot.of(profile);
    final second = await reopenPhase(scenario, profile, probes: true);
    return _states[key] = _Reopened(
      at,
      first,
      second,
      reopened,
      ProfileSnapshot.of(profile),
    );
  }

  List<Violation> _afterCrash(_Reopened state) {
    final at = state.at;
    final r = _recording;
    final (before, after) = (r.before, r.after);
    return [
      ..._ended(at, state.first, null),
      ..._ended(at, state.second, null),
      ...recoverableBoundary(
        at: at,
        before: before,
        after: after,
        reopened: state.reopened,
      ),
      ...recoveredOnAccess(at: at, first: state.reopened, second: state.again),
      ...quarantineHasCause(at: at, start: before, end: state.again),
      ...neverLocked(
        at: at,
        before: r.onBefore.probes,
        after: r.onAfter.probes,
        reopened: state.second.answers?.probes ?? const {},
      ),
      ..._nothingDeleted(at, state.reopened),
      ...recoveredBeforeRead(
        at: at,
        before: r.onBefore.read,
        after: r.onAfter.read,
        reopened: state.first.answers?.read,
      ),
    ];
  }

  List<Violation> _nothingDeleted(String at, ProfileSnapshot state) =>
      nothingDeleted(
        at: at,
        before: _recording.beforeIntegrity,
        after: _recording.afterIntegrity,
        reopened: ProfileIntegrity.of(state),
      );

  // One session: a transient error or a lost answer, then the next access
  // and, for an unknown answer, a retry.

  Future<List<Violation>> _inSession(
    String family,
    Fault fault,
    Iterable<IoOp> ops,
  ) async {
    final violations = <Violation>[];
    for (final op in ops) {
      final at = '$family/${op.key}';
      if (!_selected(at)) continue;
      _ran.add(at);
      final profile = await _workspace.fresh();
      final phase = await sessionPhase(
        scenario,
        profile,
        FaultPlan.at(op.key, fault),
      );
      _verbose(at, phase);
      final state = ProfileSnapshot.of(profile);
      _show(at, state);
      violations.addAll(_afterSession(at, op.key, phase, state));
    }
    return violations;
  }

  List<Violation> _afterSession(
    String at,
    OpKey key,
    Phase phase,
    ProfileSnapshot state,
  ) {
    final answers = phase.answers;
    final ended = _ended(at, phase, key);
    if (answers == null) return ended;
    final (before, after) = (_recording.before, _recording.after);
    return [
      ...ended,
      ...transientDeferred(at: at, afterClear: answers.accessed!),
      ...quarantineHasCause(at: at, start: before, end: state),
      ...verdictsHold(
        before: before,
        after: after,
        results: [(at, answers.verdict!, answers.accessed!)],
      ),
      if (answers.retried case final retried?)
        ...retryIdempotent(
          at: at,
          retried: retried,
          after: after,
          state: state,
        ),
      ..._nothingDeleted(at, state),
    ];
  }

  // Faults inside the recovery a crash left pending.

  /// The crash states that leave a journal record waiting, once each, of
  /// those whose `<name>/<key>` [mayRun] allows.
  Future<List<_CrashCase>> _pendingStates(
    bool Function(String crashAt) mayRun,
  ) async {
    final pending = <_CrashCase>[];
    for (final op in _recording.mutating) {
      for (final (name, fault) in _crashFaults) {
        final crashAt = '$name/${op.key}';
        if (!mayRun(crashAt)) continue;
        final c = await _crash('crash/$crashAt', op.key, fault);
        if (c.firstOfState && c.crashed.pending.isNotEmpty) pending.add(c);
      }
    }
    return pending;
  }

  /// An I/O error at each effect of the first access after each pending
  /// crash, and a read that saw its file change: both the documented
  /// "cannot be read right now", which must leave the record pending.
  Future<List<Violation>> _recoveryFamily() => _twoLevel(
    'recoveryFault',
    (op) => [
      ('eio', const FailBefore(IoError.eio)),
      if (op.kind == IoKind.read)
        ('changedWhileRead', const FailBefore(IoError.changedWhileRead)),
    ],
    _recoveryCase,
  );

  /// A file briefly missing at each read of the first access after each
  /// pending crash, as a synced folder can show. Recovery cannot tell it
  /// from one another program deleted, which the contract quarantines, so
  /// a quarantine is allowed here; losing data or leaving the record
  /// waiting is not.
  Future<List<Violation>> _missingFamily() => _twoLevel(
    'recoveryMissing',
    (op) => [
      if (op.kind.reads)
        ('spuriousMissing', const FailBefore(IoError.spuriousMissing)),
    ],
    _recoveryCase,
  );

  /// A second kill before or after each effect of the first access after
  /// each pending crash, then a third start: the recovery itself must be
  /// recoverable.
  Future<List<Violation>> _secondCrashFamily() => _twoLevel(
    'recoveryCrash',
    (op) => op.kind.reads ? const [] : _crashFaults,
    _secondCrash,
  );

  /// For each crash state that leaves a record pending, [faults] planted
  /// at each effect of the first access after it, one case each, run by
  /// [run]; a quick run samples them.
  Future<List<Violation>> _twoLevel(
    String family,
    List<(String, Fault)> Function(IoOp op) faults,
    Future<List<Violation>> Function(
      String at,
      _CrashCase c,
      OpKey key,
      Fault fault,
    )
    run,
  ) async {
    final pending = await _pendingStates(
      (crashAt) => _mayRun('$family/$crashAt'),
    );
    String caseAt(_CrashCase c, String name, IoOp op) =>
        '$family/${c.at.substring('crash/'.length)}/$name/${op.key}';
    final cases = [
      for (final c in pending)
        for (final op in c.state.first.trace.skip(_recording.setup))
          for (final (name, fault) in faults(op))
            if (_selected(caseAt(c, name, op)))
              (caseAt(c, name, op), c, op, fault),
    ];
    // A filtered run is a replay: every case it names runs.
    final chosen = options.exhaustive || options.only != null
        ? cases
        : _sample(cases, (c) => c.$1, _sampled, options.seed);
    if (chosen.length < cases.length) _sampledFamilies.add(family);
    final violations = <Violation>[];
    for (final (at, c, op, fault) in chosen) {
      _ran.add(at);
      violations.addAll(await run(at, c, op.key, fault));
    }
    return violations;
  }

  Future<List<Violation>> _recoveryCase(
    String at,
    _CrashCase c,
    OpKey key,
    Fault fault,
  ) async {
    final profile = await _workspace.fresh();
    await commandPhase(scenario, profile, FaultPlan.at(c.key, c.fault));
    final start = ProfileSnapshot.of(profile);
    final phase = await recoveryPhase(
      scenario,
      profile,
      FaultPlan.at(key, fault),
    );
    _verbose(at, phase);
    final state = ProfileSnapshot.of(profile);
    _show(at, state);
    final faulted = phase.answers?.faulted;
    // Recovery cannot tell a participant briefly missing from one another
    // program deleted, which the contract sets aside; any other file it
    // reads missing is no cause.
    final missing =
        fault is FailBefore &&
        fault.error == IoError.spuriousMissing &&
        _mayBeDeleted(key.path);
    final aside = state.quarantine.length > start.quarantine.length;
    return [
      ..._ended(at, phase, key, expected: c.state.first.trace),
      // "Cannot be read right now" is an answer the app shows, not a throw.
      if (faulted != null && faulted.startsWith('threw '))
        Violation('O5', at, 'the read that met the fault $faulted'),
      if (!missing) ...quarantineHasCause(at: at, start: start, end: state),
      ...transientDeferred(at: at, afterClear: state),
      if (!missing || !aside)
        ...recoverableBoundary(
          at: at,
          before: _recording.before,
          after: _recording.after,
          reopened: state,
        ),
      ..._nothingDeleted(at, state),
    ];
  }

  /// The recovery after [c] killed at [key] by [fault], then reopened as
  /// after any crash; crash states the same byte for byte share a reopen.
  Future<List<Violation>> _secondCrash(
    String at,
    _CrashCase c,
    OpKey key,
    Fault fault,
  ) async {
    final profile = await _workspace.fresh();
    await commandPhase(scenario, profile, FaultPlan.at(c.key, c.fault));
    final phase = await reopenPhase(
      scenario,
      profile,
      plan: FaultPlan.at(key, fault),
    );
    _verbose(at, phase);
    final state = await _reopen(at, profile, ProfileSnapshot.of(profile));
    _show(at, state.reopened);
    return [
      ..._ended(at, phase, key, crash: true, expected: c.state.first.trace),
      if (phase.ended == Ended.returned || phase.ended == Ended.threw)
        Violation('D', at, 'ran past its crash: ${phase.detail}'),
      if (state.at == at) ..._afterCrash(state),
    ];
  }

  // Another program's change between the crash and the reopen.

  Future<List<Violation>> _perturbedFamily() async {
    final violations = <Violation>[];
    final pending = await _pendingStates(
      (crashAt) => scenario.perturbations.any(
        (perturbation) => _mayRun('perturbed/${perturbation.name}/$crashAt'),
      ),
    );
    for (final c in pending) {
      for (final perturbation in scenario.perturbations) {
        final crashAt = c.at.substring('crash/'.length);
        final at = 'perturbed/${perturbation.name}/$crashAt';
        if (!_selected(at)) continue;
        _ran.add(at);
        violations.addAll(await _perturbedCase(at, c, perturbation));
      }
    }
    return violations;
  }

  Future<List<Violation>> _perturbedCase(
    String at,
    _CrashCase c,
    Perturbation perturbation,
  ) async {
    final profile = await _workspace.fresh();
    await commandPhase(scenario, profile, FaultPlan.at(c.key, c.fault));
    await perturbation.apply(profile);
    final perturbed = ProfileSnapshot.of(profile);
    final first = await reopenPhase(scenario, profile);
    _verbose(at, first);
    final reopened = ProfileSnapshot.of(profile);
    final second = await reopenPhase(scenario, profile);
    final again = ProfileSnapshot.of(profile);
    _show(at, reopened);
    final expected = perturbation.expectFor(perturbed);
    final changed = _changedBy(c.crashed, perturbed);
    final moveAgain = perturbation.movedAgain;
    final refused = moveAgain == null
        ? null
        : await Isolate.run(
            () => runZoned(
              () => moveAgain(profile),
              zoneSpecification: ZoneSpecification(print: (_, _, _, _) {}),
            ),
          );
    return [
      ..._ended(at, first, null),
      ..._ended(at, second, null),
      ...recoveredOnAccess(at: at, first: reopened, second: again),
      for (final violation in nothingDeleted(
        at: at,
        before: ProfileIntegrity.of(perturbed),
        after: _recording.afterIntegrity,
        reopened: ProfileIntegrity.of(reopened),
      ))
        // Rows in a file left as it was name the chapter where it was.
        if (expected != Expected.finishedNotFollowed ||
            !changed.any(
              (name) => violation.detail.startsWith(
                'orphaned training record ${name.split('/').last}:',
              ),
            ))
          violation,
      ...switch (expected) {
        Expected.quarantinedWhole => _quarantinedWhole(at, perturbed, again),
        Expected.putBack => _putBack(at, perturbed, again),
        Expected.finished => _finished(at, perturbed, again, first),
        Expected.finishedNotFollowed => _finishedNotFollowed(
          at,
          changed,
          perturbed,
          again,
        ),
      },
      if (perturbation.kept?.call(again) case final lost?)
        Violation(dataLost, at, 'the change was lost: $lost'),
      if (refused != null)
        Violation('O5', at, 'the chapter could not move again: $refused'),
    ];
  }

  /// The system-of-record files another program changed from [crashed] to
  /// [perturbed].
  Set<String> _changedBy(ProfileSnapshot crashed, ProfileSnapshot perturbed) {
    final (was, now) = (crashed.projection, perturbed.projection);
    return {
      for (final name in {...was.keys, ...now.keys})
        if (was[name] != now[name]) name,
    };
  }

  /// Finished around the [changed] files, which no plan could read: they
  /// hold exactly what the change left, every other file what the command
  /// wrote, and the finished record is set aside.
  List<Violation> _finishedNotFollowed(
    String at,
    Set<String> changed,
    ProfileSnapshot perturbed,
    ProfileSnapshot state,
  ) {
    final (left, after, now) = (
      perturbed.projection,
      _recording.after.projection,
      state.projection,
    );
    final aside = state.quarantine.toSet().difference(
      perturbed.quarantine.toSet(),
    );
    return [
      for (final name in changed)
        if (now[name] != left[name])
          Violation('O4', at, 'recovery wrote over the change to $name'),
      for (final name in {...after.keys, ...now.keys})
        if (!changed.contains(name) && after[name] != now[name])
          Violation(
            'O1',
            at,
            'the command did not land at $name: '
                '${after[name] ?? 'absent'} -> ${now[name] ?? 'absent'}',
          ),
      if (aside.isEmpty) Violation('O4', at, 'the record was not set aside'),
    ];
  }

  /// Finished over the change: nothing set aside, and the first read
  /// answers as after the command.
  List<Violation> _finished(
    String at,
    ProfileSnapshot perturbed,
    ProfileSnapshot again,
    Phase first,
  ) => [
    ...quarantineHasCause(at: at, start: perturbed, end: again),
    ...recoveredBeforeRead(
      at: at,
      before: _recording.onAfter.read,
      after: _recording.onAfter.read,
      reopened: first.answers?.read,
    ),
  ];

  List<Violation> _quarantinedWhole(
    String at,
    ProfileSnapshot perturbed,
    ProfileSnapshot state,
  ) {
    final applied = projectionDiff(perturbed.projection, state.projection);
    final aside = state.quarantine.toSet().difference(
      perturbed.quarantine.toSet(),
    );
    return [
      if (applied.isNotEmpty)
        Violation('O4', at, 'recovery wrote over the change:\n$applied'),
      if (aside.isEmpty) Violation('O4', at, 'the record was not set aside'),
    ];
  }

  /// Set aside and undone: each file holds what the change left it holding
  /// or what it held before the command, and the record is set aside.
  List<Violation> _putBack(
    String at,
    ProfileSnapshot perturbed,
    ProfileSnapshot state,
  ) {
    final (was, changed) = (_recording.before.projection, perturbed.projection);
    final written = {
      for (final MapEntry(:key, :value) in state.projection.entries)
        if (value != changed[key] && value != was[key]) key: value,
    };
    final aside = state.quarantine.toSet().difference(
      perturbed.quarantine.toSet(),
    );
    return [
      if (written.isNotEmpty)
        Violation('O4', at, 'recovery wrote over the change: $written'),
      if (aside.isEmpty) Violation('O4', at, 'the record was not set aside'),
    ];
  }

  // How a phase ended.

  /// A hang (O5), a command that threw rather than answering committed,
  /// rejected or unknown (O2), and a run whose effects before [key] were not
  /// those of [expected] (the recorded trace by default): nondeterminism.
  List<Violation> _ended(
    String at,
    Phase phase,
    OpKey? key, {
    bool crash = false,
    List<IoOp>? expected,
  }) => [
    if (phase.ended == Ended.hung)
      Violation('O5', at, 'hung; the last effect was ${phase.detail}'),
    if (phase.ended == Ended.threw && !crash)
      Violation('O2', at, 'threw instead of answering: ${phase.detail}'),
    if (key != null)
      if (_diverged(expected ?? _recording.trace, phase.trace, key)
          case final detail?)
        Violation('D', at, detail),
  ];

  // The ledger and the report.

  Future<void> check(
    String family,
    Future<List<Violation>> Function() cases,
  ) async {
    final found = <String, Violation>{
      for (final v in await cases()) '${v.at}/${v.contract}': v,
    };
    final known = [
      for (final id in scenario.known.keys)
        if (id.startsWith('$family/')) (id, ledgerPattern(id)),
    ];
    // A loss is never a known finding, whatever an entry's pattern says.
    final unexpected = [
      for (final MapEntry(:key, :value) in found.entries)
        if (value.contract == dataLost ||
            !known.any((entry) => entry.$2.hasMatch(key)))
          value,
    ];
    bool shows(RegExp pattern) => found.keys.any(pattern.hasMatch);
    // Where only some cases ran (a sample, a replay), a finding shows while
    // any of its entries does: one whose entries name consequences it has
    // in some crash states only is not stale when the cases chosen show
    // another of them. Where every case ran, each entry must show.
    final partial = options.only != null || _sampledFamilies.contains(family);
    final showing = {
      for (final (id, pattern) in known)
        if (shows(pattern)) scenario.known[id],
    };
    final stale = [
      for (final (id, pattern) in known)
        if (!shows(pattern) &&
            !(partial && showing.contains(scenario.known[id])) &&
            _couldShow(id))
          id,
    ];
    if (unexpected.isEmpty && stale.isEmpty) return;
    fail(_report(unexpected, stale));
  }

  /// Whether a case the ledger entry [id] names ran this time: a sampled or
  /// filtered one that did not cannot be said to have stopped showing. Nor
  /// can an entry naming many cases of a sampled family, which may show in
  /// only some of them: only a full run says that finding is gone.
  bool _couldShow(String id) {
    final at = id.substring(0, id.lastIndexOf('/'));
    if (at.contains('*') && _sampledFamilies.contains(at.split('/').first)) {
      return false;
    }
    return _ran.any(ledgerPattern(at).hasMatch);
  }

  String _report(List<Violation> unexpected, List<String> stale) {
    final out = StringBuffer();
    for (final v in unexpected) {
      out
        ..writeln(v)
        ..writeln("  replay: CAP_FAULT_ONLY='${scenario.name}/${v.at}'");
      final shown = _shown[v.at];
      if (shown != null && shown.isNotEmpty) {
        out.writeln('  the profile against after:\n$shown');
      }
    }
    for (final id in stale) {
      out.writeln(
        'no longer shows, so take it off the ledger: $id '
        '(${scenario.known[id]})',
      );
    }
    return '$out';
  }

  /// Keeps what [state] holds against after, for a report on [at].
  void _show(String at, ProfileSnapshot state) {
    final lines = const LineSplitter().convert(
      snapshotDiff(_recording.after, state),
    );
    _shown[at] = [for (final line in lines.take(40)) '    $line'].join('\n');
  }

  void _verbose(String at, Phase phase) {
    if (options.only == null) return;
    // ignore: avoid_print
    print(
      '$at: ${phase.ended.name} ${phase.detail}\n'
      '${[for (final op in phase.trace) '  ${op.key}'].join('\n')}',
    );
  }
}

/// Whether [path], relative to the root, is a participant of an operation
/// or holds one, which another program may delete: under Documents, or
/// books.json.
bool _mayBeDeleted(String path) =>
    path == 'Documents' ||
    path.startsWith('Documents/') ||
    path == 'Support/books.json';

/// Crash states compared by their bytes, with the stamps a journal record
/// or a kept version carries made the same.
String _stateKey(ProfileSnapshot state) => [
  for (final MapEntry(:key, :value) in state.entries.entries)
    '${withoutStamps(key)} ${_digest(state, key, value)}',
].join('\n');

String _digest(ProfileSnapshot state, String name, SnapshotEntry entry) {
  if (entry is! FileEntry) return entry.digest;
  return switch (state.classOf(name)) {
    Authority.journal || Authority.kept =>
      '${sha256.convert(utf8.encode(withoutStamps(state.text(name)!)))}',
    _ => entry.digest,
  };
}

/// Why [trace] did not run as [expected] up to [key], or null: the effects
/// before it must be the same, and [key] must be reached.
String? _diverged(List<IoOp> expected, List<IoOp> trace, OpKey key) {
  final at = expected.indexWhere((op) => op.key == key);
  for (var i = 0; i <= at; i++) {
    if (i >= trace.length) return 'stopped before #$i ${expected[i].key}';
    if (trace[i].key != expected[i].key) {
      return 'diverged at #$i: ${trace[i].key}, recorded ${expected[i].key}';
    }
  }
  return null;
}

/// [count] of [items], those whose [key] hashes lowest with [seed]: a
/// case is chosen or not whatever else the trace holds, so a step added to
/// a store changes a sample only by the cases it brings.
List<T> _sample<T>(
  List<T> items,
  String Function(T item) key,
  int count,
  int seed,
) {
  if (items.length <= count) return items;
  final ranked = [
    for (final (i, item) in items.indexed)
      ('${sha256.convert(utf8.encode('$seed/${key(item)}'))}', i),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  final chosen = {for (final (_, i) in ranked.take(count)) i};
  return [
    for (final (i, item) in items.indexed)
      if (chosen.contains(i)) item,
  ];
}

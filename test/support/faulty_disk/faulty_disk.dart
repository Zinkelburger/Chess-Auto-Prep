// FaultyDisk runs a storage command on a real folder with every filesystem
// effect under it seen and numbered: the dart:io entities built inside the
// run (TracingOverrides) and the native calls of document_file_io
// (runWithNativeCalls). A FaultPlan plants one fault at one effect. After a
// planted crash the disk is frozen: every later effect throws SimulatedCrash
// and changes nothing, so the handlers above it cannot tidy up the way a
// killed process never could.
import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import 'fault_plan.dart';
import 'io_trace.dart';
import 'posix_link.dart';
import 'traced_directory.dart';

/// The process was killed at [at]; null when a run hung before any effect.
/// An [Error], so a handler that tells disk failures from bugs does not take
/// it for a disk problem.
final class SimulatedCrash extends Error {
  SimulatedCrash(this.at);
  final OpKey? at;

  @override
  String toString() => 'SimulatedCrash at $at';
}

sealed class RunEnd<T> {
  const RunEnd();
}

final class Returned<T> extends RunEnd<T> {
  const Returned(this.value);
  final T value;
}

final class Threw<T> extends RunEnd<T> {
  const Threw(this.error, this.stack);
  final Object error;
  final StackTrace stack;
}

/// A planted crash at [at], whatever the command did after it.
final class Crashed<T> extends RunEnd<T> {
  const Crashed(this.at);
  final OpKey at;
}

/// Still running at the limit; [at] is the last effect it reached. Nothing
/// may wait forever on a dead disk.
final class Hung<T> extends RunEnd<T> {
  const Hung(this.at);
  final OpKey? at;
}

final class DiskRun<T> {
  const DiskRun(this.trace, this.end, {this.atCrash});
  final List<IoOp> trace;
  final RunEnd<T> end;

  /// The folder when the disk froze.
  final DiskSnapshot? atCrash;
}

final class FaultyDisk {
  FaultyDisk(this.root);
  final Directory root;

  DiskSnapshot snapshot() => DiskSnapshot.of(root.path);

  /// Runs [body] with [plan]. Build the stores inside [body]: only entities
  /// made in the run are traced, and untracedWrites catches any that are not.
  Future<DiskRun<T>> run<T>(
    FaultPlan plan,
    Future<T> Function() body, {
    Duration limit = const Duration(seconds: 20),
  }) async {
    final disk = DiskSession(p.normalize(p.absolute(root.path)), plan);
    final end = Completer<RunEnd<T>>();
    final timer = Timer(limit, () {
      if (!end.isCompleted) end.complete(Hung(disk.stop()));
    });
    unawaited(
      IOOverrides.runWithIOOverrides(
        () => runWithNativeCalls(disk.native, () => Future.sync(body)),
        TracingOverrides(disk),
      ).then<void>(
        (value) {
          if (end.isCompleted) return;
          final at = disk.crashedAt;
          end.complete(at == null ? Returned(value) : Crashed(at));
        },
        onError: (Object error, StackTrace stack) {
          if (end.isCompleted) return;
          final at = disk.crashedAt;
          end.complete(at == null ? Threw(error, stack) : Crashed(at));
        },
      ),
    );
    final outcome = await end.future;
    timer.cancel();
    return DiskRun(
      List.unmodifiable(disk.recorder.ops),
      outcome,
      atCrash: disk.atCrash,
    );
  }
}

/// One run's view of the disk: what it recorded, which fault fired, and
/// whether it froze. The traced entities call [effect] and [effectSync].
final class DiskSession {
  DiskSession(String root, this.plan) : recorder = TraceRecorder(root);

  final FaultPlan plan;
  final TraceRecorder recorder;
  var _fired = 0;
  var _frozen = false;
  OpKey? crashedAt;
  DiskSnapshot? atCrash;

  /// [body] on the real disk, with the entities it makes untraced.
  R real<R>(R Function() body) => IOOverrides.runWithIOOverrides(body, _plain);

  /// Freezes the disk at the limit; returns the last effect reached.
  OpKey? stop() {
    _freeze();
    return recorder.ops.lastOrNull?.key;
  }

  Future<R> effect<R>(
    IoKind kind,
    String path,
    Future<R> Function() call, {
    String? to,
    required R Function(IoError error) failed,
    Future<void> Function()? midway,
  }) async {
    final op = _begin(kind, path, to);
    if (op == null) return real(call);
    final fault = _faultAt(op);
    if (fault is Pause) {
      await fault.arrive();
      _checkFrozen();
    }
    switch (fault) {
      case CrashBefore():
        _crash(op);
      case CrashMidway():
        if (midway == null) throw ArgumentError('$op has no midway state');
        await real(midway);
        _crash(op);
      case CrashAfter():
        // Killed once the call returned; what it answered is lost.
        await Future.sync(
          () => real(call),
        ).then<void>((_) {}, onError: (Object _) {});
        _crash(op);
      case FailBefore(:final error):
        return failed(error);
      case FailAfter(:final error):
        await real(call);
        return failed(error);
      case Pause() || null:
        return real(call);
    }
  }

  R effectSync<R>(
    IoKind kind,
    String path,
    R Function() call, {
    String? to,
    required R Function(IoError error) failed,
    void Function()? midway,
  }) {
    final op = _begin(kind, path, to);
    if (op == null) return real(call);
    switch (_faultAt(op)) {
      case Pause():
        throw StateError('$op is synchronous and cannot pause');
      case CrashBefore():
        _crash(op);
      case CrashMidway():
        if (midway == null) throw ArgumentError('$op has no midway state');
        real(midway);
        _crash(op);
      case CrashAfter():
        try {
          real(call);
        } on Object {
          // Killed once the call returned; what it answered is lost.
        }
        _crash(op);
      case FailBefore(:final error):
        return failed(error);
      case FailAfter(:final error):
        real(call);
        return failed(error);
      case null:
        return real(call);
    }
  }

  /// The runner for document_file_io, answering as its adapter would.
  Future<T> native<T>(
    NativeCall call,
    List<String> paths,
    Future<T> Function() real,
  ) {
    final path = paths.first;
    final to = paths.length == 2 ? paths.last : null;
    Never fail(String message, String on, String label, IoError error) =>
        throw FileSystemException(message, on, OSError(label, error.errno));
    return switch (call) {
      NativeCall.observeFile => effect(
        IoKind.read,
        path,
        real,
        failed: (error) => _observation(error) as T,
      ),
      NativeCall.observeFileBatch => _observeBatch(paths, real),
      NativeCall.observeDirectory => effect(
        IoKind.stat,
        path,
        real,
        failed: (error) =>
            (status: _status(error), identity: null, volume: null) as T,
      ),
      NativeCall.syncFile => effect(
        IoKind.sync,
        path,
        real,
        failed: (error) => fail(
          'File synchronization failed',
          path,
          'Native file sync',
          error,
        ),
      ),
      NativeCall.syncDirectory => effect(
        IoKind.syncDir,
        path,
        real,
        failed: (error) => fail(
          'Directory synchronization unavailable or failed',
          path,
          'Native directory sync',
          error,
        ),
      ),
      NativeCall.replaceFile => effect(
        IoKind.publishReplace,
        path,
        real,
        to: to,
        failed: (error) => fail(
          'File replacement failed. Recovery copy, if present: '
              '$path.previous-$pid-${DateTime.now().microsecondsSinceEpoch}',
          to!,
          'Native replacement',
          error,
        ),
      ),
      NativeCall.installNewFile => effect(
        IoKind.publishNew,
        path,
        real,
        to: to,
        midway: () async => linkPosix(path, to!),
        failed: (error) => fail(
          'Exclusive publication failed',
          to!,
          'Native publication',
          error,
        ),
      ),
      NativeCall.movePathNoReplace => effect(
        IoKind.moveNoReplace,
        path,
        real,
        to: to,
        failed: (error) =>
            fail('Exclusive path move failed', to!, 'Native move', error),
      ),
    };
  }

  /// One read per path the batch observed, each of which a fault can take.
  Future<T> _observeBatch<T>(
    List<String> paths,
    Future<T> Function() real,
  ) async {
    if (!paths.any(recorder.covers)) return real();
    _checkFrozen();
    final observed = await real() as List<NativeFileObservation>;
    final answers = <NativeFileObservation>[];
    for (final (i, value) in observed.indexed) {
      answers.add(
        await effect(
          IoKind.read,
          paths[i],
          () async => value,
          failed: _observation,
        ),
      );
    }
    return List<NativeFileObservation>.unmodifiable(answers) as T;
  }

  IoOp? _begin(IoKind kind, String path, String? to) {
    if (!recorder.covers(path) && (to == null || !recorder.covers(to))) {
      return null;
    }
    _checkFrozen();
    return recorder.add(kind, path, to: to);
  }

  Fault? _faultAt(IoOp op) {
    if (_fired >= plan.times || !plan.plantedAt(op)) return null;
    _fired++;
    return plan.fault;
  }

  /// Throws SimulatedCrash when the disk is frozen and [path] is under the
  /// root: for bytes an open handle would still hand the OS.
  void guard(String path) {
    if (recorder.covers(path)) _checkFrozen();
  }

  void _checkFrozen() {
    if (!_frozen) return;
    throw SimulatedCrash(crashedAt ?? recorder.ops.lastOrNull?.key);
  }

  Never _crash(IoOp op) {
    crashedAt = op.key;
    _freeze();
    throw SimulatedCrash(op.key);
  }

  void _freeze() {
    if (_frozen) return;
    _frozen = true;
    atCrash = DiskSnapshot.of(recorder.root);
  }
}

NativeFileObservation _observation(IoError error) => NativeFileObservation(
  status: _status(error),
  error: error == IoError.changedWhileRead ? 0 : error.errno,
);

/// The native status: 1 missing, 2 an errno, 3 changed during the read.
int _status(IoError error) => switch (error) {
  IoError.spuriousMissing => 1,
  IoError.changedWhileRead => 3,
  _ => 2,
};

/// Real dart:io entities, whatever zone the call is made from.
final class _PlainOverrides extends IOOverrides {}

final _plain = _PlainOverrides();

/// [body] on the real disk, untraced, whatever zone it is called from: for
/// taking a snapshot, never for the command under test.
R onRealDisk<R>(R Function() body) =>
    IOOverrides.runWithIOOverrides(body, _plain);

/// Every entry under a folder: `dir`, `link <target>` or `file <sha256>`,
/// by its path relative to the folder with `/` separators.
final class DiskSnapshot {
  const DiskSnapshot._(this.root, this.entries);

  factory DiskSnapshot.of(String root) =>
      onRealDisk(() => DiskSnapshot._(root, _walk(root)));

  final String root;
  final Map<String, String> entries;

  /// The entries that are new, gone or different since [before].
  List<String> changedFrom(DiskSnapshot before) => [
    for (final name in {...before.entries.keys, ...entries.keys})
      if (before.entries[name] != entries[name]) name,
  ]..sort();

  @override
  bool operator ==(Object other) =>
      other is DiskSnapshot &&
      other.entries.length == entries.length &&
      changedFrom(other).isEmpty;

  @override
  int get hashCode => Object.hashAllUnordered(
    entries.entries.map((entry) => Object.hash(entry.key, entry.value)),
  );

  @override
  String toString() => [
    for (final MapEntry(:key, :value) in entries.entries) '$key $value',
  ].join('\n');
}

Map<String, String> _walk(String root) {
  final folder = Directory(root);
  final entries = SplayTreeMap<String, String>();
  if (!folder.existsSync()) return entries;
  for (final entry in folder.listSync(recursive: true, followLinks: false)) {
    final name = p.split(p.relative(entry.path, from: root)).join('/');
    entries[name] = switch (entry) {
      Link() => 'link ${entry.targetSync()}',
      Directory() => 'dir',
      File() => 'file ${sha256.convert(entry.readAsBytesSync())}',
      _ => 'other',
    };
  }
  return entries;
}

/// The entries that differ between [before] and [after] with no mutating
/// effect in [trace] on them: a write that went around the seam, such as a
/// store built outside the run. [unmanaged] names the paths another writer
/// keeps, such as SQLite's databases.
List<String> untracedWrites(
  DiskSnapshot before,
  DiskSnapshot after,
  List<IoOp> trace, {
  bool Function(String relative)? unmanaged,
}) {
  String relative(String path) => relativeName(after.root, path);
  final touched = [
    for (final op in trace)
      if (!op.kind.reads)
        for (final path in [op.path, ?op.to]) (op.kind, relative(path)),
  ];
  return [
    for (final name in after.changedFrom(before))
      if (!(unmanaged?.call(name) ?? false) &&
          !touched.any((effect) => _explains(effect.$1, effect.$2, name)))
        name,
  ];
}

bool _explains(IoKind kind, String touched, String changed) {
  // A temporary folder is traced by its prefix; the OS picks the rest of
  // its name, and what is written inside it needs its own effect.
  if (touched.endsWith('*')) {
    return p.posix.dirname(changed) == p.posix.dirname(touched) &&
        p.posix
            .basename(changed)
            .startsWith(p.posix.basename(touched).replaceFirst('*', ''));
  }
  if (touched == changed) return true;
  return switch (kind) {
    // A folder deleted or moved takes everything in it along.
    IoKind.delete ||
    IoKind.rename ||
    IoKind.moveNoReplace => p.posix.isWithin(touched, changed),
    // A recursive create makes the missing parents too.
    IoKind.mkdir ||
    IoKind.create ||
    IoKind.link => p.posix.isWithin(changed, touched),
    // ReplaceFileW can leave the replaced bytes beside the staged file.
    IoKind.publishReplace => changed.startsWith('$touched.previous-'),
    _ => false,
  };
}

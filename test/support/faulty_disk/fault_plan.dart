// Where a FaultyDisk run goes wrong, and how: a fault planted at one effect.
import 'dart:async';
import 'dart:io';

import 'io_trace.dart';

sealed class Fault {
  const Fault();
}

/// Killed before the call: the effect does not happen and the disk freezes.
final class CrashBefore extends Fault {
  const CrashBefore();
}

/// Killed once the call returned: the effect happened and the disk freezes.
final class CrashAfter extends Fault {
  const CrashAfter();
}

/// Killed inside a call made of several steps: a published file linked to
/// its new name but not unlinked from the staged one (POSIX only), a torn
/// prefix of a write, or only the first missing parent of a recursive
/// mkdir. Only those effects have a midway state.
final class CrashMidway extends Fault {
  const CrashMidway();
}

/// The call fails with [error] and has no effect, [times] tries running.
final class FailBefore extends Fault {
  const FailBefore(this.error, {this.times = 1});
  final IoError error;
  final int times;
}

/// The effect happens and then [error] is reported: a lost answer.
final class FailAfter extends Fault {
  const FailAfter(this.error);
  final IoError error;
}

/// Holds the call until the test calls [release]; [reached] completes when
/// the call gets there. The call then runs, unless the disk froze meanwhile.
final class Pause extends Fault {
  Pause();

  final _reached = Completer<void>();
  final _released = Completer<void>();

  Future<void> get reached => _reached.future;

  void release() {
    if (!_released.isCompleted) _released.complete();
  }

  /// Called by the disk when the call arrives; waits for [release].
  Future<void> arrive() {
    if (!_reached.isCompleted) _reached.complete();
    return _released.future;
  }
}

/// The failures a disk gives, with the code each platform reports. On POSIX
/// a Windows-only failure takes the nearest errno.
enum IoError {
  eio(5, 1117, 'Input/output error'),
  ebusy(16, 170, 'Device or resource busy'),
  enospc(28, 112, 'No space left on device'),
  eacces(13, 5, 'Permission denied'),
  sharingViolation(16, 32, 'The file is being used by another process'),
  lockViolation(11, 33, 'Part of the file is locked by another process'),

  /// A native observation saw the file change while it read it (status 3).
  /// A call that is not an observation reports [eio] instead.
  changedWhileRead(5, 1117, 'Input/output error'),

  /// The file is briefly not there, as a synced folder can show.
  spuriousMissing(2, 2, 'No such file or directory'),

  /// A call the filesystem does not offer: a folder flush on a VirtualBox
  /// shared folder or some CIFS mounts, say.
  einval(22, 87, 'Invalid argument');

  const IoError(this._posix, this._windows, this.message);

  final int _posix;
  final int _windows;
  final String message;

  int get errno => Platform.isWindows ? _windows : _posix;

  /// Whether dart:io calls this a [PathAccessException].
  bool get deniesAccess => switch (this) {
    eacces => true,
    sharingViolation || lockViolation => Platform.isWindows,
    _ => false,
  };
}

/// The exception dart:io throws for [error] from a call it describes as
/// [message] on [path].
FileSystemException fileSystemFailure(
  IoError error,
  String message,
  String path,
) {
  final os = OSError(error.message, error.errno);
  if (error == IoError.spuriousMissing) {
    return PathNotFoundException(path, os, message);
  }
  if (error.deniesAccess) return PathAccessException(path, os, message);
  return FileSystemException(message, path, os);
}

/// No fault, or one [fault] at the effect [key] names (or the first that
/// [matches]). A fault with more than one try also takes the tries after it
/// at the same kind and paths.
final class FaultPlan {
  const FaultPlan.none() : key = null, matches = null, fault = null;
  const FaultPlan.at(OpKey this.key, Fault this.fault) : matches = null;
  const FaultPlan.where(bool Function(IoOp op) this.matches, Fault this.fault)
    : key = null;

  final OpKey? key;
  final bool Function(IoOp op)? matches;
  final Fault? fault;

  /// How many effects the fault takes before the disk behaves again.
  int get times => switch (fault) {
    null => 0,
    FailBefore(:final times) => times,
    _ => 1,
  };

  bool plantedAt(IoOp op) {
    final key = this.key;
    if (key != null) {
      return key.sameEffect(op.key) && op.key.occurrence >= key.occurrence;
    }
    return matches?.call(op) ?? false;
  }
}

/// [error] at every effect [matches] picks, for the whole run: a filesystem
/// that never offers a call rather than one that failed once.
FaultPlan lastingFault(bool Function(IoOp op) matches, IoError error) =>
    FaultPlan.where(matches, FailBefore(error, times: 1 << 30));

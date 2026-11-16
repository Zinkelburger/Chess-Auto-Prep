import 'dart:io';

import 'package:sqlite3/sqlite3.dart' show SqliteException;

/// What stopped a disk operation, when it is something the player can do
/// something about. Anything else is said as the failure alone, and the
/// error itself goes to the log.
enum DiskProblem {
  full('The disk is full.'),
  denied('Permission was denied.'),
  readOnly('The disk is read-only.'),
  missing('The file or folder was not found.');

  const DiskProblem(this.sentence);

  /// What the screen says after the sentence naming what failed.
  final String sentence;
}

/// What [error] says the player can act on, or null when it says nothing
/// they can use.
DiskProblem? diskProblemOf(Object error) => switch (error) {
  // SQLITE_FULL, or SQLITE_IOERR_SHMSIZE: no room to open the
  // write-ahead log's shared-memory index.
  SqliteException(:final resultCode, :final extendedResultCode)
      when resultCode == 13 || extendedResultCode == 4874 =>
    DiskProblem.full,
  FileSystemException(:final osError?) => _fromErrno(osError.errorCode),
  _ => null,
};

DiskProblem? _fromErrno(int code) {
  if (Platform.isWindows) {
    return switch (code) {
      39 || 112 => DiskProblem.full,
      5 => DiskProblem.denied,
      19 => DiskProblem.readOnly,
      2 || 3 => DiskProblem.missing,
      _ => null,
    };
  }
  // EDQUOT, out of quota, is a full disk to the player.
  final quota = Platform.isMacOS ? 69 : 122;
  return switch (code) {
    28 => DiskProblem.full,
    _ when code == quota => DiskProblem.full,
    1 || 13 => DiskProblem.denied,
    30 => DiskProblem.readOnly,
    2 => DiskProblem.missing,
    _ => null,
  };
}

/// The problem a stored detail names, when it is one of [DiskProblem]'s
/// sentences ([failureDetail] writes them in place of the system's words).
DiskProblem? diskProblemIn(String detail) {
  for (final problem in DiskProblem.values) {
    if (problem.sentence == detail) return problem;
  }
  return null;
}

/// [failed], the sentence naming what could not be done, then what the
/// player can do about [error] when it says.
String failedBecause(String failed, Object error) =>
    switch (diskProblemOf(error)) {
      final problem? => '$failed ${problem.sentence}',
      null => failed,
    };

/// [failed], then the [DiskProblem] a stored [detail] names when it names
/// one; any other detail is for the log only.
String failedWithDetail(String failed, String detail) =>
    switch (diskProblemIn(detail)) {
      final problem? => '$failed ${problem.sentence}',
      null => failed,
    };

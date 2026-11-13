import 'dart:io';

import 'package:chess_auto_prep/storage/disk_problems.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' show SqliteException;

FileSystemException _os(int posix, int windows) => FileSystemException(
  'Cannot open file',
  '/x.pgn',
  OSError('system words', Platform.isWindows ? windows : posix),
);

void main() {
  test('what the disk says is named in plain words', () {
    expect(diskProblemOf(_os(28, 112)), DiskProblem.full);
    expect(diskProblemOf(_os(13, 5)), DiskProblem.denied);
    expect(diskProblemOf(_os(30, 19)), DiskProblem.readOnly);
    expect(diskProblemOf(_os(2, 3)), DiskProblem.missing);
    expect(
      diskProblemOf(SqliteException(extendedResultCode: 13, message: 'full')),
      DiskProblem.full,
    );
  });

  test('anything else names nothing, so only the failure is said', () {
    expect(diskProblemOf(_os(5, 1117)), isNull, reason: 'an I/O error');
    expect(diskProblemOf(const FileSystemException('no OS error')), isNull);
    expect(diskProblemOf(StateError('Bad state')), isNull);
    expect(
      failedBecause('Could not save.', StateError('x')),
      'Could not save.',
    );
    expect(
      failedBecause('Could not save.', _os(28, 112)),
      'Could not save. The disk is full.',
    );
  });

  test('a stored detail names a problem only when it is one of the '
      'sentences', () {
    expect(
      failedWithDetail('Could not save.', 'The disk is read-only.'),
      'Could not save. The disk is read-only.',
    );
    expect(
      failedWithDetail('Could not save.', 'FileSystemException: x'),
      'Could not save.',
    );
  });
}

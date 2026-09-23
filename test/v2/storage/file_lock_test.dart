// The lock the old app and v2 share. The protocol is written out again here,
// so a change to either side of it fails this test rather than a user's save.
import 'dart:async';
import 'dart:io';

import 'package:chess_auto_prep/v2/storage/file_lock.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../support/lock_path.dart';
import 'store_fixture.dart';

void main() {
  late StoreFixture fixture;

  setUp(() async => fixture = await StoreFixture.create());
  tearDown(() => fixture.dispose());

  test('two actions on one folder do not overlap', () async {
    final folder = fixture.documents;
    final order = <String>[];
    final first = withDirectoryLock(folder, () async {
      order.add('first in');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      order.add('first out');
    });
    final second = withDirectoryLock(folder, () async {
      order.add('second in');
    });
    await Future.wait([first, second]);
    expect(order, ['first in', 'first out', 'second in']);
  });

  test(
    'a folder slow to look up still takes its turn in the order asked',
    () async {
      final answered = Completer<void>();
      // One folder asked for twice; the first ask looks it up slowly, as a
      // synced or network folder can.
      final slow = _SlowToLookUp(fixture.documents, answered.future);
      final order = <String>[];
      final first = withDirectoryLock(slow, () async => order.add('first'));
      final second = withDirectoryLock(
        fixture.documents,
        () async => order.add('second'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      answered.complete();
      await Future.wait([first, second]);
      expect(order, ['first', 'second']);
    },
  );

  test('a failed action still hands the folder on', () async {
    final folder = fixture.documents;
    await expectLater(
      withDirectoryLock(folder, () async => throw const FormatException('no')),
      throwsFormatException,
    );
    expect(await withDirectoryLock(folder, () async => 'ran'), 'ran');
  });

  test('the lock file is the one the old app takes', () async {
    await withDirectoryLock(fixture.documents, () async {
      expect(await File(await lockPathOf(fixture.documents)).exists(), isTrue);
    });
  });

  test('a rename waits while another app holds the documents root, then goes '
      'through', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, 'A *\n');
    // The old app locks the documents root to rename a chapter, so v2 has
    // to take the same lock or the two would move one file at once.
    final other = sqlite3.open(await lockPathOf(fixture.documents));
    other.execute('PRAGMA busy_timeout = 0');
    other.execute('BEGIN IMMEDIATE');
    var done = false;
    final renamed = fixture.store
        .rename(ref, 'Mainline.pgn', expected: revision)
        .whenComplete(() => done = true);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(done, isFalse, reason: 'the other app still holds the root');
    expect(await File(ref.path).exists(), isTrue);
    other.execute('ROLLBACK');
    other.close();
    expect(await renamed, isA<Moved>());
    expect(await File(fixture.ref('KID/Mainline.pgn').path).exists(), isTrue);
  });

  test(
    'a save waits while another app holds the folder, then goes through',
    () async {
      final ref = fixture.ref('KID/Main.pgn');
      final before = oneGame('1. d4');
      final after = oneGame('1. d4 Nf6');
      final revision = await fixture.put(ref, before);
      final folder = Directory(p.dirname(ref.path));
      final other = sqlite3.open(await lockPathOf(folder));
      other.execute('PRAGMA busy_timeout = 0');
      other.execute('BEGIN IMMEDIATE');
      var done = false;
      final save = fixture
          .edit(ref, after, revision)
          .whenComplete(() => done = true);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(done, isFalse, reason: 'the other writer still holds the folder');
      expect(await File(ref.path).readAsString(), before);
      other.execute('ROLLBACK');
      other.close();
      expect(await save, isA<Saved>());
      expect(await File(ref.path).readAsString(), after);
    },
  );
}

/// A real folder whose lookups answer only once the future it is given
/// completes. The lock reads nothing else of a folder.
final class _SlowToLookUp implements Directory {
  _SlowToLookUp(this._folder, this._answered);

  final Directory _folder;
  final Future<void> _answered;

  @override
  String get path => _folder.path;

  @override
  Future<bool> exists() async {
    await _answered;
    return _folder.exists();
  }

  @override
  bool existsSync() => _folder.existsSync();

  @override
  Future<String> resolveSymbolicLinks() async {
    await _answered;
    return _folder.resolveSymbolicLinks();
  }

  @override
  String resolveSymbolicLinksSync() => _folder.resolveSymbolicLinksSync();

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The old app's formula: `<system temp>/chess-auto-prep-file-locks/` and the
/// FNV-1a of the resolved absolute directory path.

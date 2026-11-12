// The directory lock every copy of the app takes, within one process and
// across processes.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/storage/file_lock.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/other_copy_lock.dart';
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

  test('a rename waits while another copy of the app holds the documents '
      'root, then goes through', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, 'A *\n');
    // Another copy of the app locks the documents root to rename a chapter,
    // so a rename takes the same lock or the two would move one file at once.
    final release = await holdLockElsewhere(fixture.documents);
    var done = false;
    final renamed = fixture.store
        .rename(ref, 'Mainline.pgn', expected: revision)
        .whenComplete(() => done = true);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(done, isFalse, reason: 'the other copy still holds the root');
    expect(await File(ref.path).exists(), isTrue);
    await release();
    expect(await renamed, isA<Moved>());
    expect(await File(fixture.ref('KID/Mainline.pgn').path).exists(), isTrue);
  });

  test('a save waits while another copy of the app holds the folder, then goes '
      'through', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final before = oneGame('1. d4');
    final after = oneGame('1. d4 Nf6');
    final revision = await fixture.put(ref, before);
    final folder = Directory(p.dirname(ref.path));
    final release = await holdLockElsewhere(folder);
    var done = false;
    final save = fixture
        .edit(ref, after, revision)
        .whenComplete(() => done = true);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(done, isFalse, reason: 'the other writer still holds the folder');
    expect(await File(ref.path).readAsString(), before);
    await release();
    expect(await save, isA<Saved>());
    expect(await File(ref.path).readAsString(), after);
  });

  group('the lock files', () {
    late Directory temp;
    setUp(() async => temp = await Directory.systemTemp.createTemp('locks-'));
    tearDown(() => temp.delete(recursive: true));

    Future<T> withTemp<T>(Future<T> Function() body) =>
        IOOverrides.runZoned(body, getSystemTempDirectory: () => temp);

    // FNV-1a of the folder's key, written as sixteen hex digits: the name
    // every copy of the app derives for one folder's lock.
    String lockName(String key) {
      var hash = 0xcbf29ce484222325;
      for (final byte in utf8.encode(key)) {
        hash ^= byte;
        hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
      }
      return '${hash.toRadixString(16).padLeft(16, '0')}.sqlite3';
    }

    test('live in a folder made on first use', () async {
      final locks = Directory(p.join(temp.path, 'chess-auto-prep-file-locks'));
      expect(locks.existsSync(), isFalse);
      expect(
        await withTemp(
          () => withDirectoryLock(fixture.documents, () async => 7),
        ),
        7,
      );
      expect(locks.existsSync(), isTrue);
    });

    test('a damaged lock file fails the action plainly, at once', () async {
      // A folder whose hash prints as sixteen digits with no sign, so the
      // name depends on its padding too.
      late Directory folder;
      late String key;
      for (var i = 0; ; i++) {
        folder = Directory(p.join(fixture.documents.path, 'f$i'))..createSync();
        key = p.normalize(folder.resolveSymbolicLinksSync());
        if (!lockName(key).startsWith('-')) break;
      }
      final locks = Directory(p.join(temp.path, 'chess-auto-prep-file-locks'))
        ..createSync();
      File(
        p.join(locks.path, lockName(key)),
      ).writeAsStringSync('not a database, not even close to one' * 100);
      var ran = false;
      await expectLater(
        withTemp(() => withDirectoryLock(folder, () async => ran = true)),
        throwsA(isA<FileSystemException>()),
      );
      expect(ran, isFalse);
    }, timeout: const Timeout(Duration(seconds: 20)));
  });
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

import 'dart:async';
import 'dart:io';

import 'package:chess_auto_prep/v2/storage/book_file.dart';
import 'package:chess_auto_prep/v2/storage/atomic_write.dart';
import 'package:chess_auto_prep/v2/storage/book_snapshot.dart';
import 'package:chess_auto_prep/v2/storage/recovery_gate.dart';
import 'package:chess_auto_prep/v2/storage/book_list.dart';
import 'package:chess_auto_prep/v2/storage/file_lock.dart';
import 'package:chess_auto_prep/v2/storage/pending_writes.dart';
import 'package:chess_auto_prep/v2/storage/settings.dart';
import 'package:chess_auto_prep/v2/storage/settings_store.dart';
import 'package:chess_auto_prep/v2/workspace/books.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('failed book snapshot remains retryable after owner disposal', () async {
    final pending = PendingWrites();
    final disk = _Books();
    final books = Books(
      store: disk,
      root: '/repertoires',
      pendingWrites: pending,
    );
    await books.load();
    books.create('Retained');
    await books.settled;
    expect(await pending.settle(), contains('Books'));
    await books.load();
    expect(books.books.single.name, 'Retained');
    books.dispose();
    disk.fail = false;
    await pending.retry(disk);
    expect(await pending.settle(), isNull);
    expect(disk.value.books.single.name, 'Retained');
  });

  test(
    'a reload begun before edits cannot replace coalesced accepted books',
    () async {
      final pending = PendingWrites();
      final disk = _Books()..fail = false;
      final books = Books(
        store: disk,
        root: '/repertoires',
        pendingWrites: pending,
      );
      addTearDown(books.dispose);
      await books.load();
      disk.reading = Completer<BookList>();
      final loading = books.load();
      disk.writing = Completer<void>();
      books.create('First');
      books.create('Second');
      disk.reading!.complete(BookList.empty);
      await loading;
      disk.writing!.complete();
      await pending.settle();
      expect(books.books.map((book) => book.name), ['First', 'Second']);
      expect(disk.value.books.map((book) => book.name), ['First', 'Second']);
    },
  );

  test('a late book read cannot rebase an already accepted write', () async {
    final root = await Directory.systemTemp.createTemp('books-reload-');
    addTearDown(() => root.delete(recursive: true));
    final file = File(p.join(root.path, 'books.json'));
    const original = BookList(
      books: [Book(id: 'a', name: 'Original')],
    );
    const outside = BookList(
      books: [Book(id: 'x', name: 'Outside')],
    );
    const local = BookList(
      books: [Book(id: 'b', name: 'Local')],
    );
    await file.writeAsString(original.encode());
    final store = BookFile(
      root,
      recovery: RecoveryGate(
        documents: Directory(p.join(root.path, 'Documents')),
        support: root,
      ),
    );
    await store.read();
    await file.writeAsString(outside.encode());
    final acquired = Completer<void>();
    final release = Completer<void>();
    final held = withDirectoryLock(root, () async {
      acquired.complete();
      await release.future;
    });
    await acquired.future;
    final loading = store.read();
    final writing = store
        .write(local)
        .then<Object?>((_) => null, onError: (Object error) => error);
    // Reads now share the recovery domain and wait for the writer lock too.
    release.complete();
    await held;
    await loading;
    expect(await writing, isA<StateError>());
    expect(await file.readAsString(), outside.encode());
  });

  test(
    'a late settings load cannot discard an edit or rebase its write',
    () async {
      final root = await Directory.systemTemp.createTemp('settings-reload-');
      addTearDown(() => root.delete(recursive: true));
      final file = File(p.join(root.path, 'settings.json'));
      await file.writeAsString(Settings.defaults.toJson());
      final store = SettingsStore(support: root);
      addTearDown(store.dispose);
      await store.load();
      final outside = Settings.defaults.copyWith(engineCores: 8);
      await file.writeAsString(outside.toJson());
      final acquired = Completer<void>();
      final release = Completer<void>();
      final held = withDirectoryLock(root, () async {
        acquired.complete();
        await release.future;
      });
      await acquired.future;
      final loading = store.load();
      final writing = store.update(store.value.copyWith(engineCores: 4));
      await loading;
      release.complete();
      await held;
      await writing;
      expect(store.value.engineCores, 4);
      expect(store.problem, contains('another instance'));
      expect(await file.readAsString(), outside.toJson());
    },
  );

  test(
    'a book snapshot already published can be republished on retry',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'books-acknowledgement-',
      );
      addTearDown(() => root.delete(recursive: true));
      final store = BookFile(
        root,
        recovery: RecoveryGate(
          documents: Directory(p.join(root.path, 'Documents')),
          support: root,
        ),
      );
      await store.read();
      final target = p.join(root.path, 'books.json');
      final obstacle = await Directory(target).create();
      const accepted = BookList(
        books: [Book(id: 'a', name: 'Accepted')],
      );
      await expectLater(
        store.write(accepted),
        throwsA(isA<FileSystemException>()),
      );
      await obstacle.delete();
      // Model replacement having landed despite a failed acknowledgement.
      await File(target).writeAsString(accepted.encode());
      await store.write(accepted);
      expect(await File(target).readAsString(), accepted.encode());
    },
  );

  test(
    'a settings snapshot already published can be republished on retry',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'settings-acknowledgement-',
      );
      addTearDown(() => root.delete(recursive: true));
      final pending = PendingWrites();
      var failAcknowledgement = true;
      final store = SettingsStore(
        support: root,
        publish: (path, bytes) async {
          await replaceFile(path, bytes);
          if (failAcknowledgement) {
            throw const FileSystemException('lost acknowledgement');
          }
        },
      )..pendingWrites = pending;
      addTearDown(store.dispose);
      await store.load();
      final target = p.join(root.path, 'settings.json');
      final accepted = store.value.copyWith(engineCores: 4);
      await store.update(accepted);
      expect(store.problem, isNotNull);
      expect(await File(target).readAsString(), accepted.toJson());
      expect(await pending.settle(), contains('Settings'));
      final obligation = pending.unfinished(store).single;
      failAcknowledgement = false;
      await store.retry();
      expect(store.problem, isNull);
      expect(obligation.committed, isTrue);
      expect(await pending.settle(), isNull);
      expect(await File(target).readAsString(), accepted.toJson());
    },
  );

  test(
    'a book snapshot already published can be superseded after unknown acknowledgement',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'books-acknowledgement-',
      );
      addTearDown(() => root.delete(recursive: true));
      var failAcknowledgement = true;
      final store = BookFile(
        root,
        publish: (path, bytes, {installed}) async {
          await replaceFile(path, bytes, installed: installed);
          if (failAcknowledgement) {
            throw const FileSystemException('lost acknowledgement');
          }
        },
        recovery: RecoveryGate(
          documents: Directory(p.join(root.path, 'Documents')),
          support: root,
        ),
      );
      await store.read();
      final target = p.join(root.path, 'books.json');
      const accepted = BookList(
        books: [Book(id: 'a', name: 'Accepted')],
      );
      await expectLater(
        store.write(accepted),
        throwsA(isA<FileSystemException>()),
      );
      expect(await File(target).readAsString(), accepted.encode());
      failAcknowledgement = false;
      const latest = BookList(
        books: [Book(id: 'b', name: 'Latest')],
      );
      await store.write(latest);
      expect(await File(target).readAsString(), latest.encode());
    },
  );

  test(
    'a settings snapshot already published can be superseded after unknown acknowledgement',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'settings-acknowledgement-',
      );
      addTearDown(() => root.delete(recursive: true));
      final pending = PendingWrites();
      var failAcknowledgement = true;
      final store = SettingsStore(
        support: root,
        publish: (path, bytes) async {
          await replaceFile(path, bytes);
          if (failAcknowledgement) {
            throw const FileSystemException('lost acknowledgement');
          }
        },
      )..pendingWrites = pending;
      addTearDown(store.dispose);
      await store.load();
      final target = p.join(root.path, 'settings.json');
      final accepted = store.value.copyWith(engineCores: 4);
      await store.update(accepted);
      expect(store.problem, isNotNull);
      expect(await File(target).readAsString(), accepted.toJson());
      expect(await pending.settle(), contains('Settings'));
      final obligation = pending.unfinished(store).single;
      failAcknowledgement = false;
      final latest = accepted.copyWith(engineCores: 8);
      await store.update(latest);
      expect(store.problem, isNull);
      expect(obligation.committed, isTrue);
      expect(await pending.settle(), isNull);
      expect(await File(target).readAsString(), latest.toJson());
    },
  );

  test('failed settings snapshot remains retryable after disposal', () async {
    final root = await Directory.systemTemp.createTemp('settings-lifetime-');
    addTearDown(() => root.delete(recursive: true));
    final pending = PendingWrites();
    final settings = SettingsStore(support: root)..pendingWrites = pending;
    await settings.load();
    final obstacle = Directory(p.join(root.path, 'settings.json'));
    await obstacle.create();
    await settings.update(settings.value.copyWith(engineCores: 4));
    expect(await pending.settle(), contains('Settings'));
    settings.dispose();
    await obstacle.delete();
    await pending.retry(settings);
    expect(await pending.settle(), isNull);
    final saved = Settings.fromJson(await File(obstacle.path).readAsString());
    expect(saved.engineCores, 4);
  });
}

final class _Books implements BookStore {
  var fail = true;
  BookList value = BookList.empty;
  Completer<BookList>? reading;
  Completer<void>? writing;
  @override
  Future<BookList> read() async => reading?.future ?? value;
  @override
  Future<BookSnapshot> snapshot() async => BookSnapshot(value: await read());

  @override
  Future<BookSnapshot> write(BookList next) async {
    if (writing case final held?) await held.future;
    if (fail) throw const FileSystemException('disk full');
    value = next;
    return BookSnapshot(value: next);
  }
}

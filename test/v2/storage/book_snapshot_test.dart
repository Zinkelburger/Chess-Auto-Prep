import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/storage/book_file.dart';
import 'package:chess_auto_prep/v2/storage/atomic_write.dart';
import 'package:chess_auto_prep/v2/workspace/books.dart';
import 'package:chess_auto_prep/v2/storage/book_list.dart';
import 'package:chess_auto_prep/v2/storage/document_probe.dart';
import 'package:chess_auto_prep/v2/storage/recovery_gate.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late Directory documents;
  late Directory support;
  late BookFile store;
  const books = BookList(
    active: 'a',
    books: [
      Book(id: 'a', name: 'Preparation', repertoires: {'Course'}),
    ],
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('book-snapshot-');
    documents = Directory(p.join(root.path, 'Documents'));
    support = Directory(p.join(root.path, 'Support'));
    store = BookFile(
      support,
      recovery: RecoveryGate(documents: documents, support: support),
    );
  });

  tearDown(() => root.delete(recursive: true));

  test('native absence carries a profile-bound proof', () async {
    final snapshot = await store.snapshot();
    expect(snapshot.value.books, isEmpty);
    expect(snapshot.source, isNotNull);
    expect(snapshot.source!.revision, isNull);
    expect(snapshot.source!.supportPath, support.path);
    expect(snapshot.source!.canonicalSupport, support.path);
  });

  test('acknowledged write returns the exact native installed proof', () async {
    final saved = await store.write(books);
    final found =
        await probeDocument(p.join(support.path, 'books.json')) as FileFound;
    expect(saved.source, isNotNull);
    expect(saved.source!.revision, found.revision);
    expect(saved.source!.revision!.nativeIdentity, found.identity);
    expect(saved.value.activeBook!.name, 'Preparation');
  });

  BookFile fileStore({Directory? configured, BookPublish? publish}) => BookFile(
    configured ?? support,
    recovery: RecoveryGate(
      documents: documents,
      support: configured ?? support,
    ),
    publish: publish ?? replaceFile,
  );

  test('read proof and raw baseline describe the exact bytes decoded', () async {
    await support.create();
    final text =
        '\ufeff${books.encode().replaceFirst('"version": 1,', '"version": 1, "unknown": [true, 7],')}';
    final file = File(p.join(support.path, 'books.json'));
    await file.writeAsBytes(utf8.encode(text));
    final snapshot = await store.snapshot();
    final observed = await probeDocument(file.path) as FileFound;
    expect(snapshot.value.activeBook!.name, 'Preparation');
    expect(snapshot.source!.revision, observed.revision);
    expect(snapshot.source!.revision!.nativeIdentity, observed.identity);
    expect(await store.expectedText(), text);
    expect(() => snapshot.value.books.clear(), throwsUnsupportedError);
    expect(
      () => snapshot.value.activeBook!.repertoires.add('Else'),
      throwsUnsupportedError,
    );
  });

  test(
    'a replacement after publication cannot supply the saved proof',
    () async {
      final owner = fileStore(
        publish: (path, bytes, {installed}) async {
          await replaceFile(path, bytes, installed: installed);
          await replaceFile(path, utf8.encode(BookList.empty.encode()));
        },
      );
      final saved = await owner.write(books);
      final current =
          await probeDocument(p.join(support.path, 'books.json')) as FileFound;
      expect(saved.value.activeBook!.name, 'Preparation');
      expect(saved.source!.revision, isNot(current.revision));
      expect(saved.source!.revision!.nativeIdentity, isNot(current.identity));
    },
  );

  test(
    'failed acknowledgement retains owner source until exact retry',
    () async {
      await store.write(books);
      var fail = true;
      final native = fileStore(
        publish: (path, bytes, {installed}) async {
          await replaceFile(path, bytes, installed: installed);
          if (fail) throw const FileSystemException('lost acknowledgement');
        },
      );
      final owner = Books(
        store: native,
        root: p.join(documents.path, 'repertoires'),
      );
      addTearDown(owner.dispose);
      await owner.load();
      final before = owner.source;
      owner.rename(owner.active!, 'Updated');
      await owner.settled;
      expect(owner.current, isFalse);
      expect(owner.canRetry, isTrue);
      expect(owner.source, same(before));
      fail = false;
      await owner.retry();
      expect(owner.current, isTrue);
      expect(owner.active!.name, 'Updated');
      final current =
          await probeDocument(p.join(support.path, 'books.json')) as FileFound;
      expect(owner.source!.revision!.nativeIdentity, current.identity);
      expect(owner.source!.revision, current.revision);
    },
  );

  test('a failed refresh retains the prior value and proof', () async {
    await store.write(books);
    final owner = Books(
      store: store,
      root: p.join(documents.path, 'repertoires'),
    );
    addTearDown(owner.dispose);
    await owner.load();
    final before = owner.source;
    final active = owner.active;
    await File(p.join(support.path, 'books.json')).writeAsString('unreadable');
    await owner.load();
    expect(owner.current, isFalse);
    expect(owner.active, same(active));
    expect(owner.source, same(before));
  });

  test(
    'write freezes caller membership before waiting for publication',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final native = fileStore(
        publish: (path, bytes, {installed}) async {
          entered.complete();
          await release.future;
          await replaceFile(path, bytes, installed: installed);
        },
      );
      final folders = {'Course'};
      final accepted = BookList(
        books: [Book(id: 'a', name: 'A', repertoires: folders)],
      );
      final writing = native.write(accepted);
      await entered.future;
      folders.add('Too late');
      release.complete();
      final saved = await writing;
      expect(saved.value.books.single.repertoires, {'Course'});
      expect((await native.read()).books.single.repertoires, {'Course'});
    },
  );

  test('configured alias is accepted but retargeting is refused', () async {
    await support.create();
    final alias = Link(p.join(root.path, 'Support-alias'));
    await alias.create(support.path);
    final native = fileStore(configured: Directory(alias.path));
    final saved = await native.write(books);
    expect(saved.source!.supportPath, alias.path);
    expect(saved.source!.canonicalSupport, support.path);
    final elsewhere = await Directory(p.join(root.path, 'Elsewhere')).create();
    await alias.update(elsewhere.path);
    await expectLater(native.snapshot(), throwsA(isA<StateError>()));
    await expectLater(native.write(BookList.empty), throwsA(isA<StateError>()));
    expect(await File(p.join(elsewhere.path, 'books.json')).exists(), isFalse);
    expect((await store.read()).activeBook!.name, 'Preparation');
  }, skip: !Platform.isLinux);

  test(
    'linked and non-file book participants cannot masquerade as absence',
    () async {
      await support.create();
      final target = File(p.join(root.path, 'outside.json'));
      await target.writeAsString(books.encode());
      final path = p.join(support.path, 'books.json');
      await Link(path).create(target.path);
      await expectLater(store.snapshot(), throwsA(isA<FileSystemException>()));
      await expectLater(
        store.write(BookList.empty),
        throwsA(isA<FileSystemException>()),
      );
      expect(await target.readAsString(), books.encode());
      await Link(path).delete();
      await Directory(path).create();
      await expectLater(store.snapshot(), throwsA(isA<FileSystemException>()));
    },
    skip: !Platform.isLinux,
  );

  test('one root for Documents and Support needs no nested lock', () async {
    final native = BookFile(
      root,
      recovery: RecoveryGate(documents: root, support: root),
    );
    final saved = await native.write(books).timeout(const Duration(seconds: 5));
    final read = await native.snapshot();
    expect(read.source!.revision, saved.source!.revision);
    expect(
      read.source!.revision!.nativeIdentity,
      saved.source!.revision!.nativeIdentity,
    );
  });

  test('a linked book stage cannot truncate an unrelated file', () async {
    await support.create();
    final target = File(p.join(root.path, 'unrelated.txt'));
    const preserved = 'Keep this unrelated document intact.';
    await target.writeAsString(preserved);
    final stage = Link(temporaryPathFor(p.join(support.path, 'books.json')));
    await stage.create(target.path);
    await expectLater(store.write(books), throwsA(isA<Exception>()));
    expect(await target.readAsString(), preserved);
    expect(await stage.exists(), isTrue);
    expect(await File(p.join(support.path, 'books.json')).exists(), isFalse);
  }, skip: !Platform.isLinux);
}

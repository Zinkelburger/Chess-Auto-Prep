import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/infrastructure/documents/native_pgn_document_store.dart';
import 'package:chess_auto_prep/infrastructure/training/move_attempt_store.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Directory documents;
  late Directory support;
  late File chapter;
  late IOStorageService io;
  late NativePgnDocumentStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('recovery-alias-');
    documents = await Directory(p.join(root.path, 'Documents')).create();
    support = await Directory(p.join(root.path, 'Support')).create();
    chapter = File(
      p.join(documents.path, 'repertoires', 'Opening', 'Main.pgn'),
    );
    await chapter.parent.create(recursive: true);
    await chapter.writeAsString('1. e4 e5 *');
    io = IOStorageService(documentsRoot: documents, supportRoot: support);
    store = NativePgnDocumentStore(guardOperation: io.guardDocumentOperation);
  });
  tearDown(() async {
    await Process.run('chmod', ['-R', 'u+rwX', root.path]);
    await root.delete(recursive: true);
  });

  Future<File> foreignNote() async {
    final notes = await Directory(
      p.join(support.path, 'unfinished-moves'),
    ).create();
    return File(p.join(notes.path, 'move.json')).writeAsString('{unknown');
  }

  Future<String> aliasTo(Directory target, String name) async {
    final alias = Link(p.join(root.path, name));
    await alias.create(target.path);
    return alias.path;
  }

  // v2 may leave a note behind after a crash. It is v2's to finish; it never
  // stops v1 using a document, whichever spelling reaches the document.
  for (final nested in [false, true]) {
    test(
      'open through a ${nested ? 'chapter' : 'Documents'} alias works beside a v2 note',
      () async {
        final target = nested ? chapter.parent : documents;
        final alias = await aliasTo(target, 'external-alias');
        final path = p.join(alias, p.relative(chapter.path, from: target.path));
        final note = await foreignNote();
        expect(await store.open(path), isA<PgnOpened>());
        expect(await io.readFile(path), '1. e4 e5 *');
        expect(await note.readAsString(), '{unknown');
      },
      skip: !Platform.isLinux,
    );
  }

  test('save through an alias works beside a v2 note', () async {
    final opened = await store.open(chapter.path) as PgnOpened;
    final alias = await aliasTo(chapter.parent, 'external-alias');
    final baseline = PgnSnapshot(
      path: p.join(alias, 'Main.pgn'),
      revision: opened.snapshot.revision,
      content: opened.snapshot.content,
    );
    await foreignNote();
    expect(
      await store.save(baseline, '1. d4 d5 *'),
      isNot(isA<PgnWriteFailed>()),
    );
    expect(await chapter.readAsString(), '1. d4 d5 *');
  }, skip: !Platform.isLinux);

  test('create beneath an alias works beside a v2 note', () async {
    final alias = await aliasTo(documents, 'external-alias');
    await foreignNote();
    final path = p.join(alias, 'new', 'nested', 'Main.pgn');
    expect(await store.create(path, '1. d4 *'), isNot(isA<PgnWriteFailed>()));
    expect(
      await File(p.join(documents.path, 'new', 'nested', 'Main.pgn')).exists(),
      isTrue,
    );
  }, skip: !Platform.isLinux);

  test('a parent traversal after an alias reads the sibling', () async {
    final alias = await aliasTo(chapter.parent, 'external-alias');
    final sibling = File(p.join(documents.path, 'repertoires', 'Other.pgn'));
    await sibling.writeAsString('1. c4 *');
    await foreignNote();
    expect(await io.readFile('$alias/../Other.pgn'), '1. c4 *');
  }, skip: !Platform.isLinux);

  test('unrelated external reads stay outside managed recovery', () async {
    final outside = File(p.join(root.path, 'external.pgn'));
    await outside.writeAsString('1. c4 *');
    await foreignNote();
    expect(await io.readFile(outside.path), '1. c4 *');
    expect(await store.open(outside.path), isA<PgnOpened>());
  }, skip: !Platform.isLinux);

  test(
    'unreadable candidate ancestry cannot be treated as unrelated',
    () async {
      final hidden = await Directory(p.join(root.path, 'hidden')).create();
      final alias = Link(p.join(hidden.path, 'alias'));
      await alias.create(documents.path);
      await Process.run('chmod', ['000', hidden.path]);
      try {
        await expectLater(
          io.fileStat(p.join(alias.path, 'new', 'Main.pgn')),
          throwsA(isA<FileSystemException>()),
        );
      } finally {
        await Process.run('chmod', ['u+rwX', hidden.path]);
      }
    },
    skip: !Platform.isLinux || Platform.environment['USER'] == 'root',
  );

  test('external rename rewrites managed attempts beside a v2 note', () async {
    final source = File(p.join(root.path, 'outside.pgn'));
    final destination = File(p.join(root.path, 'renamed.pgn'));
    await source.writeAsString('1. d4 *');
    final attempts = File(p.join(documents.path, MoveAttemptStore.fileName));
    await attempts.writeAsString(
      '${jsonEncode({'repertoireId': source.path, 'lineId': 'line'})}\n',
    );
    await foreignNote();
    await io.renameFile(source.path, destination.path);
    expect(await destination.readAsString(), '1. d4 *');
    expect(await attempts.readAsString(), contains(destination.path));
  }, skip: !Platform.isLinux);
}

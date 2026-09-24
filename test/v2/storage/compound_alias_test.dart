import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/storage/compound_commit.dart';
import 'package:chess_auto_prep/v2/storage/compound_write.dart';
import 'package:chess_auto_prep/v2/storage/relocation_notes.dart';
import 'package:chess_auto_prep/v2/storage/recovery_gate.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late Directory documents;
  late Directory support;
  late Directory documentAlias;
  late Directory supportAlias;
  late File document;
  const before = '[Event "Before"]\n\n1. e4 *\n';
  const after = '[Event "After"]\n\n1. e4 *\n';
  const booksBefore = '{"version":1,"books":[]}';
  const booksAfter = '{"version":1,"books":[],"changed":true}';

  CompoundCommit command(String path) => CompoundCommit(
    id: 'alias-rename',
    documentPath: path,
    documentBefore: before,
    documentAfter: after,
    booksBefore: booksBefore,
    booksAfter: booksAfter,
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('compound-alias-');
    documents = await Directory(p.join(root.path, 'Documents')).create();
    support = await Directory(p.join(root.path, 'Support')).create();
    documentAlias = Directory(p.join(root.path, 'Documents-alias'));
    supportAlias = Directory(p.join(root.path, 'Support-alias'));
    await Link(documentAlias.path).create(documents.path);
    await Link(supportAlias.path).create(support.path);
    document = await File(
      p.join(documents.path, 'Course.pgn'),
    ).writeAsString(before);
    await File(p.join(support.path, 'books.json')).writeAsString(booksBefore);
  });
  tearDown(() async => root.delete(recursive: true));

  test('recovery deduplicates aliased Documents and Support locks', () async {
    final gate = RecoveryGate(documents: documents, support: documentAlias);
    expect(
      await gate.run(() async => 'entered').timeout(const Duration(seconds: 3)),
      'entered',
    );
  }, skip: Platform.isWindows ? 'symlink privileges not assumed' : false);

  test(
    'configured Support alias still refuses linked relocation metadata',
    () async {
      final outside = await Directory(
        p.join(root.path, 'notes-outside'),
      ).create();
      await Link(p.join(support.path, 'unfinished-moves')).create(outside.path);
      final gate = RecoveryGate(documents: documents, support: supportAlias);
      await expectLater(
        gate.run(() async => 'unsafe'),
        throwsA(isA<RecoveryRequired>()),
      );
      expect(await outside.list().toList(), isEmpty);
    },
    skip: Platform.isWindows ? 'symlink privileges not assumed' : false,
  );

  for (final changedRoot in ['Documents', 'Support']) {
    test('compound owner refuses replaced $changedRoot root', () async {
      final engine = CompoundWrites(documents: documents, support: support);
      final original = changedRoot == 'Documents' ? documents : support;
      final preserved = await original.rename(
        p.join(root.path, '$changedRoot-preserved'),
      );
      final outside = await Directory(p.join(root.path, 'outside')).create();
      await Link(original.path).create(outside.path);
      await expectLater(engine.recover(), throwsA(isA<RecoveryRequired>()));
      await expectLater(
        engine.commit(command(document.path)),
        throwsA(isA<RecoveryRequired>()),
      );
      expect(await outside.list().toList(), isEmpty);
      expect(await preserved.exists(), isTrue);
    }, skip: Platform.isWindows ? 'symlink privileges not assumed' : false);
  }

  test(
    'existing configured alias cannot be retargeted after owner creation',
    () async {
      final engine = CompoundWrites(
        documents: documentAlias,
        support: supportAlias,
      );
      final notes = PendingRepoints(supportAlias, documents: documentAlias);
      final outside = await Directory(p.join(root.path, 'outside')).create();
      await Link(supportAlias.path).delete();
      await Link(supportAlias.path).create(outside.path);
      await expectLater(engine.recover(), throwsA(isA<RecoveryRequired>()));
      await expectLater(notes.read(), throwsA(isA<RecoveryRequired>()));
      expect(await outside.list().toList(), isEmpty);
      expect(
        await File(p.join(support.path, 'books.json')).readAsString(),
        booksBefore,
      );
    },
    skip: Platform.isWindows ? 'symlink privileges not assumed' : false,
  );

  for (final startAliased in [false, true]) {
    test(
      'partial rename recovers across configured aliases ($startAliased)',
      () async {
        final first = CompoundWrites(
          documents: startAliased ? documentAlias : documents,
          support: startAliased ? supportAlias : support,
          testHook: (step) async {
            if (step == CompoundWriteStep.document)
              throw StateError('interrupted');
          },
        );
        final firstPath = p.join(
          (startAliased ? documentAlias : documents).path,
          'Course.pgn',
        );
        await expectLater(first.commit(command(firstPath)), throwsStateError);
        final reopened = CompoundWrites(
          documents: startAliased ? documents : documentAlias,
          support: startAliased ? support : supportAlias,
        );
        await reopened.recover();
        final retried = await reopened.commit(
          command(
            p.join(
              (startAliased ? documents : documentAlias).path,
              'Course.pgn',
            ),
          ),
        );
        expect(retried.documentPath, document.path);
        expect(await document.readAsString(), after);
        expect(
          await File(p.join(support.path, 'books.json')).readAsString(),
          booksAfter,
        );
        final note = File(
          p.join(support.path, 'compound-writes', 'alias-rename.json'),
        );
        final bytes = await note.readAsBytes();
        expect(
          (jsonDecode(utf8.decode(bytes)) as Map)['documentPath'],
          document.path,
        );
        await reopened.recover();
        expect(await note.readAsBytes(), bytes);
      },
      skip: Platform.isWindows ? 'symlink privileges not assumed' : false,
    );
  }

  test('trusted root alias does not authorize a linked PGN parent', () async {
    final outside = await Directory(p.join(root.path, 'outside')).create();
    final target = await File(
      p.join(outside.path, 'Course.pgn'),
    ).writeAsString(before);
    await Link(p.join(documents.path, 'linked')).create(outside.path);
    final engine = CompoundWrites(
      documents: documentAlias,
      support: supportAlias,
    );
    await expectLater(
      engine.commit(
        command(p.join(documentAlias.path, 'linked', 'Course.pgn')),
      ),
      throwsA(isA<RecoveryRequired>()),
    );
    expect(await target.readAsString(), before);
    expect(
      await File(p.join(support.path, 'books.json')).readAsString(),
      booksBefore,
    );
  }, skip: Platform.isWindows ? 'symlink privileges not assumed' : false);
}

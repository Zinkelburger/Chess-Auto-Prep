import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/storage/compound_commit.dart';
import 'package:chess_auto_prep/v2/storage/compound_write.dart';
import 'package:chess_auto_prep/v2/storage/relocation_notes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _before = '[Event "Opening"]\n[ChapterName "Before"]\n\n1. e4 e5 *\n';
const _after = '[Event "Opening"]\n[ChapterName "After"]\n\n1. e4 e5 *\n';
const _booksBefore = '{"version":1,"books":[],"unknown":"preserve before"}';
const _booksAfter = '{"version":1,"books":[],"unknown":"preserve after"}';
const _training = [
  'repertoire_reviews.csv',
  'repertoire_move_progress.csv',
  'repertoire_review_history.csv',
  'repertoire_move_attempts.jsonl',
];

void main() {
  late Directory root;
  late Directory documents;
  late Directory support;
  late File document;
  late File books;
  late CompoundCommit command;

  CompoundWrites engine({CompoundWriteStep? interrupt}) => CompoundWrites(
    documents: documents,
    support: support,
    testHook: interrupt == null
        ? null
        : (step) async {
            if (step == interrupt)
              throw StateError('interrupted at ${step.name}');
          },
  );
  File note([String id = 'rename-1']) =>
      File(p.join(support.path, 'compound-writes', '$id.json'));

  setUp(() async {
    root = await Directory.systemTemp.createTemp('compound-write-');
    documents = await Directory(p.join(root.path, 'Documents')).create();
    support = await Directory(p.join(root.path, 'Support')).create();
    document = File(p.join(documents.path, 'Course.pgn'));
    books = File(p.join(support.path, 'books.json'));
    await document.writeAsString(_before);
    await books.writeAsString(_booksBefore);
    command = CompoundCommit(
      id: 'rename-1',
      documentPath: document.path,
      documentBefore: _before,
      documentAfter: _after,
      booksBefore: _booksBefore,
      booksAfter: _booksAfter,
    );
    for (final name in _training) {
      await File(
        p.join(documents.path, name),
      ).writeAsString('unchanged $name\n');
    }
  });
  tearDown(() async {
    for (final name in _training) {
      expect(
        await File(p.join(documents.path, name)).readAsString(),
        'unchanged $name\n',
      );
    }
    await Process.run('chmod', ['-R', 'u+rwX', root.path]);
    await root.delete(recursive: true);
  });

  Future<Map<String, Object?>> metadata() async =>
      jsonDecode(await note().readAsString()) as Map<String, Object?>;
  Future<void> expectPair(String text, String? membership) async {
    expect(await document.readAsString(), text);
    expect(
      await books.exists() ? await books.readAsString() : null,
      membership,
    );
  }

  CompoundCommit changed({
    String? id,
    String? path,
    String? after,
    String? afterBooks,
  }) => CompoundCommit(
    id: id ?? command.id,
    documentPath: path ?? command.documentPath,
    documentBefore: command.documentBefore,
    documentAfter: after ?? command.documentAfter,
    booksBefore: command.booksBefore,
    booksAfter: afterBooks ?? command.booksAfter,
  );

  test(
    'commit publishes both exact snapshots and retains a complete receipt',
    () async {
      final result = await engine().commit(command);
      expect(result.documentAfter, _after);
      await expectPair(_after, _booksAfter);
      expect((await metadata())['state'], 'complete');
      expect((await engine().completed(command.id))!.documentBefore, _before);
    },
  );

  for (final step in CompoundWriteStep.values) {
    test(
      'interruption after ${step.name} recovers on two restarts without duplication',
      () async {
        await expectLater(
          engine(interrupt: step).commit(command),
          throwsA(isA<StateError>()),
        );
        await engine().recover();
        await engine().recover();
        final preparedOnly = step == CompoundWriteStep.prepared;
        await expectPair(
          preparedOnly ? _before : _after,
          preparedOnly ? _booksBefore : _booksAfter,
        );
        expect(
          (await metadata())['state'],
          preparedOnly ? 'cancelled' : 'complete',
        );
        expect(
          await engine().completed(command.id),
          preparedOnly ? isNull : isNotNull,
        );
        await engine().commit(command);
        await expectPair(_after, _booksAfter);
        expect(await note().parent.list().length, 1);
      },
    );
  }

  test(
    'a completed exact retry leaves subsequent external edits intact',
    () async {
      await engine().commit(command);
      await document.writeAsString('external document');
      await books.writeAsString('{"external":true}');
      await engine().recover();
      final result = await engine().commit(command);
      expect(result.documentAfter, _after);
      await expectPair('external document', '{"external":true}');
      expect((await engine().completed(command.id))!.booksBefore, _booksBefore);
    },
  );

  for (final participant in ['document', 'books']) {
    test(
      'fresh $participant conflict refuses both writes before intent',
      () async {
        await (participant == 'document' ? document : books).writeAsString(
          'external',
        );
        await expectLater(
          engine().commit(command),
          throwsA(isA<RecoveryRequired>()),
        );
        await expectPair(
          participant == 'document' ? 'external' : _before,
          participant == 'books' ? 'external' : _booksBefore,
        );
        expect(await note().exists(), isFalse);
      },
    );
  }

  test(
    'partial commit with external books conflict preserves both files and note',
    () async {
      await expectLater(
        engine(interrupt: CompoundWriteStep.document).commit(command),
        throwsA(isA<StateError>()),
      );
      await books.writeAsString('{"external":true}');
      for (var restart = 0; restart < 2; restart++) {
        await expectLater(engine().recover(), throwsA(isA<RecoveryRequired>()));
        await expectPair(_after, '{"external":true}');
        expect((await metadata())['state'], 'committing');
      }
      await books.writeAsString(_booksBefore);
      await engine().recover();
      await expectPair(_after, _booksAfter);
    },
  );

  test(
    'external document conflict after intent prevents book publication',
    () async {
      await expectLater(
        engine(interrupt: CompoundWriteStep.intent).commit(command),
        throwsA(isA<StateError>()),
      );
      await document.writeAsString('external');
      await expectLater(engine().recover(), throwsA(isA<RecoveryRequired>()));
      await expectPair('external', _booksBefore);
    },
  );

  test('cancelled preparation must validate expected bytes again', () async {
    await expectLater(
      engine(interrupt: CompoundWriteStep.prepared).commit(command),
      throwsA(isA<StateError>()),
    );
    await engine().recover();
    await books.writeAsString('{"external":true}');
    await expectLater(
      engine().commit(command),
      throwsA(isA<RecoveryRequired>()),
    );
    await expectPair(_before, '{"external":true}');
    expect((await metadata())['state'], 'cancelled');
  });

  test('completed id cannot be reused for a different command', () async {
    await engine().commit(command);
    await expectLater(
      engine().commit(changed(after: 'different')),
      throwsA(isA<RecoveryRequired>()),
    );
    await expectPair(_after, _booksAfter);
  });

  test(
    'absent book snapshots can be created and restored by an inverse',
    () async {
      await books.delete();
      final forward = CompoundCommit(
        id: 'forward',
        documentPath: document.path,
        documentBefore: _before,
        documentAfter: _after,
        booksBefore: null,
        booksAfter: _booksAfter,
      );
      await engine().commit(forward);
      final inverse = CompoundCommit(
        id: 'inverse',
        documentPath: document.path,
        documentBefore: _after,
        documentAfter: _before,
        booksBefore: _booksAfter,
        booksAfter: null,
      );
      await expectLater(
        engine(interrupt: CompoundWriteStep.document).commit(inverse),
        throwsA(isA<StateError>()),
      );
      await engine().recover();
      await engine().recover();
      await expectPair(_before, null);
    },
  );

  for (final invalid in [
    'id',
    'outside',
    'extension',
    'utf8',
    'nul',
    'books',
  ]) {
    test(
      'invalid command $invalid cannot publish either participant',
      () async {
        final value = switch (invalid) {
          'id' => changed(id: '../escape'),
          'outside' => changed(path: p.join(root.path, 'outside.pgn')),
          'extension' => changed(path: p.join(documents.path, 'training.csv')),
          'utf8' => changed(after: '\uD800'),
          'nul' => changed(after: 'pgn\u0000'),
          _ => changed(afterBooks: '{'),
        };
        await expectLater(
          engine().commit(value),
          throwsA(isA<RecoveryRequired>()),
        );
        await expectPair(_before, _booksBefore);
      },
    );
  }

  for (final invalid in ['version', 'state', 'extra', 'id', 'json']) {
    test(
      'unsupported $invalid metadata is preserved and blocks recovery',
      () async {
        await expectLater(
          engine(interrupt: CompoundWriteStep.prepared).commit(command),
          throwsA(isA<StateError>()),
        );
        final data = await metadata();
        switch (invalid) {
          case 'version':
            data['version'] = 99;
          case 'state':
            data['state'] = 'future';
          case 'extra':
            data['unknown'] = true;
          case 'id':
            data['id'] = 'another-id';
        }
        final text = invalid == 'json' ? '{' : jsonEncode(data);
        await note().writeAsString(text);
        await expectLater(engine().recover(), throwsA(isA<RecoveryRequired>()));
        await expectPair(_before, _booksBefore);
        expect(await note().readAsString(), text);
      },
    );
  }

  test(
    'recovery can itself stop after the second publication and restart twice',
    () async {
      await expectLater(
        engine(interrupt: CompoundWriteStep.document).commit(command),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        engine(interrupt: CompoundWriteStep.books).recover(),
        throwsA(isA<StateError>()),
      );
      await expectPair(_after, _booksAfter);
      expect((await metadata())['state'], 'committing');
      await engine().recover();
      await engine().recover();
      await expectPair(_after, _booksAfter);
      expect((await metadata())['state'], 'complete');
    },
  );

  test('a PGN parent alias cannot redirect an authoritative write', () async {
    final outside = await Directory(p.join(root.path, 'outside')).create();
    final original = await File(
      p.join(outside.path, 'Course.pgn'),
    ).writeAsString(_before);
    final alias = Link(p.join(documents.path, 'alias'));
    await alias.create(outside.path);
    await expectLater(
      engine().commit(changed(path: p.join(alias.path, 'Course.pgn'))),
      throwsA(isA<RecoveryRequired>()),
    );
    expect(await original.readAsString(), _before);
    await expectPair(_before, _booksBefore);
  }, skip: Platform.isWindows ? 'symlink privileges not assumed' : false);

  test(
    'unknown metadata entries block preparation without being removed',
    () async {
      await note().parent.create();
      final unknown = File(p.join(note().parent.path, 'unknown.future'));
      await unknown.writeAsString('preserve');
      await expectLater(
        engine().commit(command),
        throwsA(isA<RecoveryRequired>()),
      );
      expect(await unknown.readAsString(), 'preserve');
      await expectPair(_before, _booksBefore);
    },
  );

  for (final protected in ['support', 'folder', 'note', 'books']) {
    test(
      'unreadable $protected cannot look like absent compound data',
      () async {
        await expectLater(
          engine(interrupt: CompoundWriteStep.intent).commit(command),
          throwsA(isA<StateError>()),
        );
        final path = switch (protected) {
          'support' => support.path,
          'folder' => note().parent.path,
          'note' => note().path,
          _ => books.path,
        };
        await Process.run('chmod', ['000', path]);
        try {
          await expectLater(
            engine().recover(),
            throwsA(isA<RecoveryRequired>()),
          );
        } finally {
          await Process.run('chmod', ['u+rwX', path]);
        }
        await expectPair(_before, _booksBefore);
        expect((await metadata())['state'], 'committing');
      },
      skip: !Platform.isLinux || Platform.environment['USER'] == 'root'
          ? 'requires Linux permissions without root'
          : false,
    );
  }

  for (final linked in ['document', 'books', 'folder', 'note']) {
    test(
      'linked $linked data cannot be followed by the compound engine',
      () async {
        final saved = File(p.join(root.path, 'untouched'));
        await saved.writeAsString(linked == 'books' ? _booksBefore : _before);
        if (linked == 'folder') {
          await Link(note().parent.path).create(root.path);
        } else if (linked == 'note') {
          await note().parent.create();
          await Link(note().path).create(saved.path);
        } else {
          final file = linked == 'document' ? document : books;
          await file.delete();
          await Link(file.path).create(saved.path);
        }
        await expectLater(
          engine().commit(command),
          throwsA(isA<RecoveryRequired>()),
        );
        expect(
          await saved.readAsString(),
          linked == 'books' ? _booksBefore : _before,
        );
      },
      skip: Platform.isWindows ? 'symlink privileges not assumed' : false,
    );
  }
}

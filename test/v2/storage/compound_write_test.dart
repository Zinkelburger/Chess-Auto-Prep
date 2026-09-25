import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/storage/compound_commit.dart';
import 'package:chess_auto_prep/v2/storage/compound_write.dart';
import 'package:chess_auto_prep/v2/storage/recovery_gate.dart';
import 'package:chess_auto_prep/v2/storage/relocation_notes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _before = '[Event "Opening"]\n[ChapterName "Before"]\n\n1. e4 e5 *\n';
const _after = '[Event "Opening"]\n[ChapterName "After"]\n\n1. e4 e5 *\n';
const _booksBefore = '{"version":1,"books":[],"unknown":"preserve before"}';
const _booksAfter = '{"version":1,"books":[],"unknown":"preserve after"}';

/// [json] cut off halfway, as a kill mid-write leaves it.
String _cutOff(String json) => json.substring(0, json.length ~/ 2);

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
            if (step == interrupt) {
              throw StateError('interrupted at ${step.name}');
            }
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

  /// Journal records still waiting to finish.
  Future<List<String>> pending() async {
    final folder = note().parent;
    if (!await folder.exists()) return const [];
    return [await for (final entry in folder.list()) p.basename(entry.path)];
  }

  /// Records set aside because they could not be read or finished.
  Future<List<String>> quarantined() async {
    final folder = Directory(p.join(support.path, 'recovery-quarantine'));
    if (!await folder.exists()) return const [];
    return [
      await for (final entry in folder.list(recursive: true))
        if (entry is! Directory) p.basename(entry.path),
    ];
  }

  CompoundCommit changed({
    String? id,
    String? path,
    String? before,
    String? after,
    String? beforeBooks,
    String? afterBooks,
  }) => CompoundCommit(
    id: id ?? command.id,
    documentPath: path ?? command.documentPath,
    documentBefore: before ?? command.documentBefore,
    documentAfter: after ?? command.documentAfter,
    booksBefore: beforeBooks ?? command.booksBefore,
    booksAfter: afterBooks ?? command.booksAfter,
  );

  test('commit publishes both snapshots and leaves no journal', () async {
    final writes = engine();
    final result = await writes.commit(command);
    expect(result.documentAfter, _after);
    await expectPair(_after, _booksAfter);
    expect(await pending(), isEmpty);
    expect((await writes.completed(command.id))!.documentBefore, _before);
  });

  for (final step in CompoundWriteStep.values.where(
    (step) => step != CompoundWriteStep.secondaryDocument,
  )) {
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
        expect(await pending(), isEmpty);
        expect(await quarantined(), isEmpty);
        // The process remembers what it finished for this profile, so an
        // exact retry through a new owner writes nothing again.
        await engine().commit(command);
        await expectPair(_after, _booksAfter);
        expect(await pending(), isEmpty);
      },
    );
  }

  test('an exact retry in the same process writes nothing again', () async {
    final writes = engine();
    await writes.commit(command);
    await document.writeAsString('external document');
    await books.writeAsString('{"external":true}');
    await writes.recover();
    final result = await writes.commit(command);
    expect(result.documentAfter, _after);
    await expectPair('external document', '{"external":true}');
  });

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
    'a half-done edit whose books changed since is set aside, not replayed',
    () async {
      await expectLater(
        engine(interrupt: CompoundWriteStep.document).commit(command),
        throwsA(isA<StateError>()),
      );
      await books.writeAsString('{"external":true}');
      await engine().recover();
      await expectPair(_after, '{"external":true}');
      expect(await pending(), isEmpty);
      expect(await quarantined(), ['compound-writes-rename-1.json']);

      // Later edits of the same files go ahead.
      await engine().commit(
        changed(
          id: 'later',
          before: _after,
          after: _before,
          beforeBooks: '{"external":true}',
          afterBooks: _booksBefore,
        ),
      );
      await expectPair(_before, _booksBefore);
    },
  );

  test(
    'an external document change after intent keeps both files as they are',
    () async {
      await expectLater(
        engine(interrupt: CompoundWriteStep.intent).commit(command),
        throwsA(isA<StateError>()),
      );
      await document.writeAsString('external');
      await engine().recover();
      await expectPair('external', _booksBefore);
      expect(await quarantined(), ['compound-writes-rename-1.json']);
    },
  );

  test('an interrupted preparation leaves nothing to recover', () async {
    await expectLater(
      engine(interrupt: CompoundWriteStep.prepared).commit(command),
      throwsA(isA<StateError>()),
    );
    await engine().recover();
    expect(await pending(), isEmpty);
    await books.writeAsString('{"external":true}');
    await expectLater(
      engine().commit(command),
      throwsA(isA<RecoveryRequired>()),
    );
    await expectPair(_before, '{"external":true}');
  });

  test('completed id cannot be reused for a different command', () async {
    final writes = engine();
    await writes.commit(command);
    await expectLater(
      writes.commit(changed(before: _after, after: 'different')),
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
      expect(await pending(), isEmpty);
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
          _ => changed(afterBooks: _cutOff(_booksAfter)),
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
      'unsupported $invalid record is set aside and the next edit works',
      () async {
        await expectLater(
          engine(interrupt: CompoundWriteStep.intent).commit(command),
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
        final text = invalid == 'json'
            ? _cutOff(jsonEncode(data))
            : jsonEncode(data);
        await note().writeAsString(text);
        await engine().recover();
        await expectPair(_before, _booksBefore);
        expect(await pending(), isEmpty);
        final aside = Directory(p.join(support.path, 'recovery-quarantine'));
        final kept = await aside
            .list(recursive: true)
            .where((entry) => entry is File)
            .cast<File>()
            .single;
        expect(await kept.readAsString(), text);

        await engine().commit(command);
        await expectPair(_after, _booksAfter);
      },
    );
  }

  test('the gate opens despite a damaged record', () async {
    await note().parent.create();
    await note().writeAsString(_cutOff(_booksBefore));
    final gate = RecoveryGate(documents: documents, support: support);
    expect(await gate.run(() async => 'opened'), 'opened');
    expect(await quarantined(), ['compound-writes-rename-1.json']);
  });

  test('a leftover staged journal from a kill is removed', () async {
    await note().parent.create();
    final stage = File(p.join(note().parent.path, '.rename-1.json.v2-tmp'));
    await stage.writeAsString(_cutOff(_booksBefore));
    await engine().recover();
    expect(await stage.exists(), isFalse);
    expect(await quarantined(), isEmpty);
    await engine().commit(command);
    await expectPair(_after, _booksAfter);
  });

  test('a leftover staged PGN from a kill does not block the edit', () async {
    final stage = File(p.join(documents.path, '.Course.pgn.v2-tmp'));
    await stage.writeAsString('half a document');
    await engine().commit(command);
    await expectPair(_after, _booksAfter);
    expect(await stage.exists(), isFalse);
  });

  test(
    'recovery can itself stop after the second publication and restart twice',
    () async {
      await expectLater(
        engine(interrupt: CompoundWriteStep.document).commit(command),
        throwsA(isA<StateError>()),
      );
      // A failure that is not about the record keeps it for the next start.
      await engine(interrupt: CompoundWriteStep.books).recover();
      await expectPair(_after, _booksAfter);
      expect(await pending(), ['rename-1.json']);
      await engine().recover();
      await engine().recover();
      await expectPair(_after, _booksAfter);
      expect(await pending(), isEmpty);
      expect(await quarantined(), isEmpty);
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

  test('an unknown entry in the journal folder is set aside', () async {
    await note().parent.create();
    final unknown = File(p.join(note().parent.path, 'unknown.future'));
    await unknown.writeAsString('preserve');
    await engine().commit(command);
    await expectPair(_after, _booksAfter);
    expect(await unknown.exists(), isFalse);
    expect(await quarantined(), ['compound-writes-unknown.future']);
  });

  for (final protected in ['note', 'books']) {
    test(
      'unreadable $protected sets the record aside without writing',
      () async {
        await expectLater(
          engine(interrupt: CompoundWriteStep.intent).commit(command),
          throwsA(isA<StateError>()),
        );
        final path = protected == 'note' ? note().path : books.path;
        await Process.run('chmod', ['000', path]);
        try {
          await engine().recover();
        } finally {
          await Process.run('chmod', ['-R', 'u+rwX', support.path]);
        }
        await expectPair(_before, _booksBefore);
        expect(await pending(), isEmpty);
        expect(await quarantined(), ['compound-writes-rename-1.json']);
      },
      skip: !Platform.isLinux || Platform.environment['USER'] == 'root'
          ? 'requires Linux permissions without root'
          : false,
    );
  }

  for (final linked in ['document', 'books', 'folder']) {
    test(
      'linked $linked data cannot be followed by the compound engine',
      () async {
        final saved = File(p.join(root.path, 'untouched'));
        await saved.writeAsString(linked == 'books' ? _booksBefore : _before);
        if (linked == 'folder') {
          await Link(note().parent.path).create(root.path);
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

  test('a linked journal record is set aside, not followed', () async {
    final saved = File(p.join(root.path, 'untouched'));
    await saved.writeAsString(_before);
    await note().parent.create();
    await Link(note().path).create(saved.path);
    await engine().commit(command);
    await expectPair(_after, _booksAfter);
    expect(await saved.readAsString(), _before);
    expect(await quarantined(), ['compound-writes-rename-1.json']);
  }, skip: Platform.isWindows ? 'symlink privileges not assumed' : false);
}

import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/storage/atomic_write.dart';
import 'package:chess_auto_prep/v2/storage/compound_commit.dart';
import 'package:chess_auto_prep/v2/storage/compound_write.dart';
import 'package:chess_auto_prep/v2/storage/relocation_notes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late Directory documents;
  late Directory support;
  late File from;
  late File to;
  late CompoundCommit command;
  const before = '[Event "Transferred"]\n\n1. d4 d5 *\n';
  const after = '[Event "Remaining"]\n\n1. e4 e5 *\n';
  const targetBefore = '[Event "Destination"]\n\n1. c4 e5 *\n';
  const targetAfter = '$targetBefore\n$before';
  const training = [
    'repertoire_reviews.csv',
    'repertoire_move_progress.csv',
    'repertoire_review_history.csv',
    'repertoire_move_attempts.jsonl',
  ];

  File note([String id = 'pair-1']) =>
      File(p.join(support.path, 'compound-writes', '$id.json'));
  CompoundWrites engine({CompoundWriteStep? interrupt}) => CompoundWrites(
    documents: documents,
    support: support,
    testHook: interrupt == null
        ? null
        : (step) async {
            if (step == interrupt) throw StateError('stop at ${step.name}');
          },
  );
  Map<String, Object?> metadata(String state) => {
    'version': 2,
    'id': command.id,
    'state': state,
    'documents': [
      for (final document in command.documents)
        <String, Object?>{
          'path': document.path,
          'before': document.before,
          'after': document.after,
        },
    ],
  };
  Future<void> record(Map<String, Object?> value) async {
    await note().parent.create();
    await note().writeAsString(jsonEncode(value));
  }

  Future<List<File>> quarantined() async {
    final folder = Directory(p.join(support.path, 'recovery-quarantine'));
    if (!await folder.exists()) return const [];
    return [
      await for (final entry in folder.list(recursive: true))
        if (entry is File) entry,
    ];
  }

  Future<bool> pending() async =>
      await note().parent.exists() && !await note().parent.list().isEmpty;

  Future<void> expectPair(String source, String target) async {
    expect(await from.readAsString(), source);
    expect(await to.readAsString(), target);
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('compound-pair-');
    documents = await Directory(p.join(root.path, 'Documents')).create();
    support = await Directory(p.join(root.path, 'Support')).create();
    from = File(p.join(documents.path, 'From.pgn'));
    to = File(p.join(documents.path, 'To.pgn'));
    await from.writeAsString(before);
    await to.writeAsString(targetBefore);
    await File(
      p.join(support.path, 'books.json'),
    ).writeAsString('opaque untouched books');
    for (final name in training) {
      await File(p.join(documents.path, name)).writeAsBytes([255, 0, 10]);
    }
    command = CompoundCommit.pair(
      id: 'pair-1',
      primary: CompoundDocument(path: from.path, before: before, after: after),
      secondary: CompoundDocument(
        path: to.path,
        before: targetBefore,
        after: targetAfter,
      ),
    );
  });
  tearDown(() async {
    expect(
      await File(p.join(support.path, 'books.json')).readAsString(),
      'opaque untouched books',
    );
    for (final name in training) {
      expect(await File(p.join(documents.path, name)).readAsBytes(), [
        255,
        0,
        10,
      ]);
    }
    await root.delete(recursive: true);
  });

  test('a two-PGN intent recovers both participants once', () async {
    await from.writeAsString(after);
    await record(metadata('committing'));
    await engine().recover();
    await engine().recover();
    await expectPair(after, targetAfter);
    expect(await pending(), isFalse);
  });

  for (final step in CompoundWriteStep.values.where(
    (step) => step != CompoundWriteStep.books,
  )) {
    test('restart twice after ${step.name} retains exact pair', () async {
      await expectLater(
        engine(interrupt: step).commit(command),
        throwsStateError,
      );
      await engine().recover();
      await engine().recover();
      expect(await pending(), isFalse);
      if (step == CompoundWriteStep.prepared) {
        await expectPair(before, targetBefore);
      }
      // An exact retry through a new owner of the same profile succeeds
      // and writes nothing again.
      await engine().commit(command);
      await expectPair(after, targetAfter);
    });
  }

  test('a retry never overwrites edits made after the pair finished', () async {
    final first = engine();
    await first.commit(command);
    expect(first.publishedRevision(command.id)?.nativeIdentity, isNotNull);
    expect(
      first.publishedRevision(command.id, path: to.path)?.nativeIdentity,
      isNotNull,
    );
    await from.delete();
    await to.writeAsString('external replacement');
    final result = await first.commit(command);
    expect(result.secondary!.after, targetAfter);
    final reopened = engine();
    expect((await reopened.commit(command)).secondary!.after, targetAfter);
    expect(await from.exists(), isFalse);
    expect(await to.readAsString(), 'external replacement');
    expect(
      reopened.publishedRevision(command.id),
      first.publishedRevision(command.id),
    );
  });

  test('same id cannot change only the second participant', () async {
    final writes = engine();
    await writes.commit(command);
    await expectLater(
      writes.commit(
        CompoundCommit.pair(
          id: command.id,
          primary: command.primary,
          secondary: CompoundDocument(
            path: to.path,
            before: targetBefore,
            after: 'different',
          ),
        ),
      ),
      throwsA(isA<RecoveryRequired>()),
    );
    await expectPair(after, targetAfter);
  });

  for (final target in [false, true]) {
    test(
      'fresh ${target ? 'target' : 'source'} conflict publishes nothing',
      () async {
        await (target ? to : from).writeAsString('external');
        await expectLater(
          engine().commit(command),
          throwsA(isA<RecoveryRequired>()),
        );
        await expectPair(
          target ? before : 'external',
          target ? 'external' : targetBefore,
        );
        expect(await note().exists(), isFalse);
      },
    );
  }

  test('recovery checks second participant before finishing source', () async {
    await record(metadata('committing'));
    await to.writeAsString('external');
    final kept = await note().readAsBytes();
    await engine().recover();
    await expectPair(before, 'external');
    expect(await pending(), isFalse);
    expect(await (await quarantined()).single.readAsBytes(), kept);
  });

  test('even an unchanged participant is a required read dependency', () async {
    final value = metadata('committing');
    final entries = value['documents']! as List<Map<String, Object?>>;
    entries[1]['after'] = targetBefore;
    await record(value);
    await to.writeAsString('external');
    await engine().recover();
    expect(await from.readAsString(), before);
    expect(await quarantined(), hasLength(1));
  });

  test(
    'a linked leftover stage is removed without touching its target',
    () async {
      final outside = await File(
        p.join(root.path, 'outside'),
      ).writeAsString('preserved');
      await Link(temporaryPathFor(to.path)).create(outside.path);
      await engine().commit(command);
      await expectPair(after, targetAfter);
      expect(await outside.readAsString(), 'preserved');
      expect(
        await FileSystemEntity.type(
          temporaryPathFor(to.path),
          followLinks: false,
        ),
        FileSystemEntityType.notFound,
      );
    },
  );

  test(
    'pair inverse is another exact transaction that survives a restart',
    () async {
      final writes = engine();
      await writes.commit(command);
      final kept = (await writes.completed(command.id))!;
      CompoundDocument inverse(CompoundDocument document) => CompoundDocument(
        path: document.path,
        before: document.after,
        after: document.before,
      );
      final undo = CompoundCommit.pair(
        id: 'pair-undo',
        primary: inverse(kept.primary),
        secondary: inverse(kept.secondary!),
      );
      await expectLater(
        engine(interrupt: CompoundWriteStep.document).commit(undo),
        throwsStateError,
      );
      await engine().recover();
      await expectPair(before, targetBefore);
      expect(await pending(), isFalse);
    },
  );

  test('BOM-bearing pair keeps exact snapshots through restart', () async {
    const mark = '\uFEFF';
    await from.writeAsString('$mark$before');
    await to.writeAsString('$mark$targetBefore');
    final marked = CompoundCommit.pair(
      id: 'marked',
      primary: CompoundDocument(
        path: from.path,
        before: '$mark$before',
        after: '$mark$after',
      ),
      secondary: CompoundDocument(
        path: to.path,
        before: '$mark$targetBefore',
        after: '$mark$targetAfter',
      ),
    );
    await expectLater(
      engine(interrupt: CompoundWriteStep.document).commit(marked),
      throwsStateError,
    );
    await engine().recover();
    expect(await from.readAsBytes(), utf8.encode('$mark$after'));
    expect(await to.readAsBytes(), utf8.encode('$mark$targetAfter'));
  });

  test('configured root alias maps both participants', () async {
    final alias = Link(p.join(root.path, 'Alias'));
    await alias.create(documents.path);
    CompoundDocument aliased(CompoundDocument document) => CompoundDocument(
      path: p.join(alias.path, p.basename(document.path)),
      before: document.before,
      after: document.after,
    );
    final aliasEngine = CompoundWrites(
      documents: Directory(alias.path),
      support: support,
    );
    final result = await aliasEngine.commit(
      CompoundCommit.pair(
        id: command.id,
        primary: aliased(command.primary),
        secondary: aliased(command.secondary!),
      ),
    );
    expect(result.secondary!.path, to.path);
    await expectPair(after, targetAfter);
  });

  final corruptions = <String, void Function(Map<String, Object?>)>{
    'unknown version': (value) => value['version'] = 3,
    'fractional version': (value) => value['version'] = 2.0,
    'unknown state': (value) => value['state'] = 'finished',
    'extra field': (value) => value['booksBefore'] = null,
    'wrong id': (value) => value['id'] = 'other',
    'one participant': (value) => (value['documents']! as List).removeLast(),
    'duplicate path': (value) =>
        ((value['documents']! as List)[1] as Map)['path'] = from.path,
    'outside path': (value) =>
        ((value['documents']! as List)[1] as Map)['path'] = p.join(
          root.path,
          'Outside.pgn',
        ),
    'unknown participant field': (value) =>
        ((value['documents']! as List)[1] as Map)['extra'] = 'x',
    'null preimage': (value) =>
        ((value['documents']! as List)[1] as Map)['before'] = null,
    'NUL snapshot': (value) =>
        ((value['documents']! as List)[1] as Map)['after'] = '\u0000',
  };
  for (final entry in corruptions.entries) {
    test('${entry.key} record is set aside and the next edit works', () async {
      final value = metadata('committing');
      entry.value(value);
      await record(value);
      final kept = await note().readAsBytes();
      await engine().recover();
      await expectPair(before, targetBefore);
      expect(await pending(), isFalse);
      expect(await (await quarantined()).single.readAsBytes(), kept);
      await engine().commit(command);
      await expectPair(after, targetAfter);
    });
  }
}

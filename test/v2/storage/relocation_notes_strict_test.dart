import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/storage/relocation_notes.dart';
import 'package:chess_auto_prep/v2/storage/training_records.dart';
import 'package:document_file_io/document_file_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late Directory documents;
  late Directory support;
  late Directory folder;
  late PendingRepoints notes;
  late RelocationNotes recovery;
  late String from;
  late String to;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('strict-move-notes-');
    documents = await Directory(p.join(root.path, 'Documents')).create();
    support = await Directory(p.join(root.path, 'Support')).create();
    folder = await Directory(p.join(support.path, 'unfinished-moves')).create();
    notes = PendingRepoints(support, documents: documents);
    recovery = RelocationNotes(
      notes: notes,
      records: TrainingRecords(documents),
    );
    from = p.join(documents.path, 'Before.pgn');
    to = p.join(documents.path, 'After.pgn');
  });
  tearDown(() async {
    await Process.run('chmod', ['-R', 'u+rwX', root.path]);
    await root.delete(recursive: true);
  });

  File note([String id = 'move']) => File(p.join(folder.path, '$id.json'));

  /// The bytes of a note set aside by recovery, or null when none was.
  Future<String?> setAside([String id = 'move']) async {
    final quarantine = Directory(p.join(support.path, 'recovery-quarantine'));
    if (!await quarantine.exists()) return null;
    await for (final entry in quarantine.list(recursive: true)) {
      if (entry is File &&
          p.basename(entry.path) == 'unfinished-moves-$id.json') {
        return entry.readAsString();
      }
    }
    return null;
  }

  Map<String, Object?> valid() => {
    'from': from,
    'to': to,
    'identity': 'original',
    'folder': false,
  };

  for (final malformed in ['{', '[]', '{}', '{"folder":false}']) {
    test(
      'malformed note $malformed is set aside intact without blocking',
      () async {
        await note().writeAsString(malformed);
        await recovery.finishOwed();
        expect(await note().exists(), isFalse);
        expect(await setAside(), malformed);
      },
    );
  }

  for (final changed in [
    'version',
    'relative',
    'outside',
    'same',
    'identity',
  ]) {
    test('unsupported note $changed blocks recovery', () async {
      final json = valid();
      switch (changed) {
        case 'version':
          json['version'] = 99;
        case 'relative':
          json['from'] = 'Before.pgn';
        case 'outside':
          json['to'] = p.join(root.path, 'outside.pgn');
        case 'same':
          json['to'] = from;
        case 'identity':
          json['identity'] = '';
      }
      await note().writeAsString(jsonEncode(json));
      await expectLater(notes.read(), throwsA(isA<RecoveryRequired>()));
      expect(await note().exists(), isTrue);
    });
  }

  test('unknown entries are preserved and block recovery', () async {
    final unknown = File(p.join(folder.path, 'future-format.bin'));
    await unknown.writeAsString('keep');
    await expectLater(notes.read(), throwsA(isA<RecoveryRequired>()));
    expect(await unknown.readAsString(), 'keep');
  });

  test('discard preserves a malformed note', () async {
    await note().writeAsString('unknown format');
    await expectLater(notes.discard('move'), throwsA(isA<RecoveryRequired>()));
    expect(await note().readAsString(), 'unknown format');
  });

  for (final protected in ['support', 'note', 'cleanup', 'lookup']) {
    test(
      'unreadable $protected metadata cannot look settled',
      () async {
        await note().writeAsString(jsonEncode(valid()));
        final path = switch (protected) {
          'support' => support.path,
          'note' => note().path,
          _ => folder.path,
        };
        await Process.run('chmod', [
          switch (protected) {
            'cleanup' => 'a-w',
            'lookup' => 'a-x',
            _ => '000',
          },
          path,
        ]);
        try {
          await expectLater(
            protected == 'cleanup' || protected == 'lookup'
                ? notes.discard('move')
                : notes.read(),
            throwsA(isA<RecoveryRequired>()),
          );
        } finally {
          await Process.run('chmod', ['u+rwX', path]);
        }
        expect(await note().exists(), isTrue);
      },
      skip: !Platform.isLinux || Platform.environment['USER'] == 'root'
          ? 'requires Linux permissions without root'
          : false,
    );
  }

  test('unsafe note ids cannot be read or recorded', () async {
    await note('.hidden').writeAsString(jsonEncode(valid()));
    await expectLater(notes.read(), throwsA(isA<RecoveryRequired>()));
    await expectLater(
      notes.record(
        '../escaped',
        from: from,
        to: to,
        identity: 'original',
        folder: false,
      ),
      throwsA(isA<RecoveryRequired>()),
    );
    expect(await File(p.join(support.path, 'escaped.json')).exists(), isFalse);
  });

  for (final linked in ['support', 'folder', 'note']) {
    test(
      'symlinked $linked metadata is refused without touching its target',
      () async {
        final elsewhere = await Directory(
          p.join(root.path, 'elsewhere'),
        ).create();
        final saved = File(p.join(elsewhere.path, 'saved.json'));
        await saved.writeAsString(jsonEncode(valid()));
        switch (linked) {
          case 'support':
            await folder.delete();
            await support.delete();
            await Link(support.path).create(elsewhere.path);
          case 'folder':
            await folder.delete();
            await Link(folder.path).create(elsewhere.path);
          case 'note':
            await Link(note().path).create(saved.path);
        }
        await expectLater(notes.read(), throwsA(isA<RecoveryRequired>()));
        expect(await saved.exists(), isTrue);
      },
      skip: Platform.isWindows ? 'symlink privilege not assumed' : false,
    );
  }

  test('a metadata directory in place of a note cannot be discarded', () async {
    await Directory(note().path).create();
    await expectLater(notes.discard('move'), throwsA(isA<RecoveryRequired>()));
    expect(await Directory(note().path).exists(), isTrue);
  });

  for (final replacementAt in ['from', 'to']) {
    test(
      'one unrelated file at $replacementAt sets the note aside, rows untouched',
      () async {
        await File(from).writeAsString('original');
        final identity = (await observeFile(from)).identity!;
        await File(from).rename(p.join(documents.path, 'kept-original'));
        await File(
          replacementAt == 'from' ? from : to,
        ).writeAsString('replacement');
        final move = UnfinishedMove(
          id: 'move',
          from: from,
          to: to,
          identity: identity,
          folder: false,
        );
        expect(await observeMove(move), isA<MoveUnclear>());
        await notes.record(
          'move',
          from: from,
          to: to,
          identity: identity,
          folder: false,
        );
        await recovery.finishOwed();
        expect(await note().exists(), isFalse);
        expect(await setAside(), isNotNull);
      },
    );
  }

  test('failed row recovery sets the note aside and keeps the rows', () async {
    await File(from).writeAsString('original');
    final identity = (await observeFile(from)).identity!;
    await File(from).rename(to);
    await notes.record(
      'move',
      from: from,
      to: to,
      identity: identity,
      folder: false,
    );
    final rows = File(p.join(documents.path, 'repertoire_reviews.csv'));
    await rows.writeAsString('not a csv header\n');
    await recovery.finishOwed();
    expect(await note().exists(), isFalse);
    expect(await setAside(), isNotNull);
    expect(await rows.readAsString(), 'not a csv header\n');
  });
}

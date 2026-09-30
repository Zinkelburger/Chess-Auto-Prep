import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/storage/relocation_notes.dart';
import 'package:document_file_io/document_file_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late Directory documents;
  late Directory support;
  late Directory folder;
  late RelocationNotes recovery;
  late String from;
  late String to;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('strict-move-notes-');
    documents = await Directory(p.join(root.path, 'Documents')).create();
    support = await Directory(p.join(root.path, 'Support')).create();
    folder = await Directory(p.join(support.path, 'unfinished-moves')).create();
    recovery = RelocationNotes(documents: documents, support: support);
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

  /// The note an older build wrote before it renamed [from] to [to].
  Future<void> leaveNote(String identity) =>
      note().writeAsString(jsonEncode({...valid(), 'identity': identity}));

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
    test('unsupported note $changed is set aside intact', () async {
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
      await recovery.finishOwed();
      expect(await note().exists(), isFalse);
      expect(await setAside(), jsonEncode(json));
    });
  }

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
        await leaveNote(identity);
        await recovery.finishOwed();
        expect(await note().exists(), isFalse);
        expect(await setAside(), isNotNull);
      },
    );
  }

  test(
    'a note whose destination cannot be read now waits for a later try',
    () async {
      await File(from).writeAsString('original');
      final identity = (await observeFile(from)).identity!;
      await File(from).rename(to);
      await leaveNote(identity);
      final rows = File(
        p.join(documents.path, 'repertoire_review_history.csv'),
      );
      await rows.writeAsString(
        'repertoire_id,line_id,timestamp_utc,rating,had_mistake,session_type\n'
        '$from,line,2026-08-31T00:00:00Z,good,false,trainer\n',
      );
      await Process.run('chmod', ['000', to]);
      try {
        await recovery.finishOwed();
      } finally {
        await Process.run('chmod', ['644', to]);
      }
      expect(await note().exists(), isTrue);
      expect(await setAside(), isNull);
      expect(await rows.readAsString(), contains('$from,line'));
      await recovery.finishOwed();
      expect(await note().exists(), isFalse);
      expect(await setAside(), isNull);
      expect(await rows.readAsString(), contains('$to,line'));
      expect(await rows.readAsString(), isNot(contains('$from,line')));
    },
    skip: !Platform.isLinux || Platform.environment['USER'] == 'root'
        ? 'requires Linux permissions without root'
        : false,
  );

  /// Review rows that name [path], as an older build left them.
  Future<File> rowsNaming(String path) =>
      File(
        p.join(documents.path, 'repertoire_review_history.csv'),
      ).writeAsString(
        'repertoire_id,line_id,timestamp_utc,rating,had_mistake,session_type\n'
        '$path,line,2026-08-31T00:00:00Z,good,false,trainer\n',
      );

  for (final linked in ['note', 'folder']) {
    test(
      'a linked $linked is never followed and leaves its target and rows',
      () async {
        await File(from).writeAsString('original');
        final identity = (await observeFile(from)).identity!;
        await File(from).rename(to);
        final rows = await rowsNaming(from);
        final elsewhere = await Directory(
          p.join(root.path, 'elsewhere'),
        ).create();
        final saved = File(p.join(elsewhere.path, 'move.json'));
        final bytes = jsonEncode({...valid(), 'identity': identity});
        await saved.writeAsString(bytes);
        switch (linked) {
          case 'note':
            await Link(note().path).create(saved.path);
          case 'folder':
            await folder.delete();
            await Link(folder.path).create(elsewhere.path);
        }
        await recovery.finishOwed();
        expect(await saved.readAsString(), bytes);
        expect(await rows.readAsString(), contains('$from,line'));
        if (linked == 'note') {
          expect(await Link(note().path).exists(), isFalse);
          final quarantine = Directory(
            p.join(support.path, 'recovery-quarantine'),
          );
          final aside = await quarantine
              .list(recursive: true, followLinks: false)
              .where((entry) => entry is Link)
              .toList();
          expect(aside.map((entry) => p.basename(entry.path)), [
            'unfinished-moves-move.json',
          ]);
        } else {
          expect(await Link(folder.path).target(), elsewhere.path);
        }
      },
      skip: Platform.isWindows ? 'symlink privilege not assumed' : false,
    );
  }

  test(
    'a destination reached through a linked folder sets the note aside',
    () async {
      final real = await Directory(p.join(documents.path, 'Real')).create();
      await Link(p.join(documents.path, 'Linked')).create(real.path);
      await File(from).writeAsString('original');
      final identity = (await observeFile(from)).identity!;
      await File(from).rename(p.join(real.path, 'After.pgn'));
      final rows = await rowsNaming(from);
      final json = {
        ...valid(),
        'to': p.join(documents.path, 'Linked', 'After.pgn'),
        'identity': identity,
      };
      await note().writeAsString(jsonEncode(json));
      await recovery.finishOwed();
      expect(await note().exists(), isFalse);
      expect(await setAside(), jsonEncode(json));
      expect(await rows.readAsString(), contains('$from,line'));
      expect(
        await File(p.join(real.path, 'After.pgn')).readAsString(),
        'original',
      );
    },
    skip: Platform.isWindows ? 'symlink privilege not assumed' : false,
  );

  test('failed row recovery sets the note aside and keeps the rows', () async {
    await File(from).writeAsString('original');
    final identity = (await observeFile(from)).identity!;
    await File(from).rename(to);
    await leaveNote(identity);
    final rows = File(p.join(documents.path, 'repertoire_reviews.csv'));
    await rows.writeAsString('not a csv header\n');
    await recovery.finishOwed();
    expect(await note().exists(), isFalse);
    expect(await setAside(), isNotNull);
    expect(await rows.readAsString(), 'not a csv header\n');
  });
}

@TestOn('linux')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/storage/backups.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/file_relocation.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/training_rows.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'store_fixture.dart';

const _id = 'folder-recovery';
const _archived = [
  'Main.pgn',
  'Nested/.cap-pgn-history/1-a-Old.pgn',
  'Nested/Upper.PGN',
];
const _old = '[Event "old"]\n\n1. e4 *\n';
const _current = '[Event "current"]\n\n1. d4 *\n';
const _orphan = '[Event "orphan"]\n\n1. c4 *\n';

void main() {
  late _Fixture f;
  setUp(() async => f = await _Fixture.create());
  tearDown(() => f.disk.dispose());

  for (final step in FileRelocationStep.values) {
    // The journal is written after `prepared`; a stop before it leaves
    // nothing to finish, and nothing moved.
    final recorded = step != FileRelocationStep.prepared;

    test(
      'folder interruption at ${step.name} finishes on the next start',
      () async {
        expect(await f.move(f.owner(interrupt: step)), isA<FolderMoveFailed>());
        await f.owner().recover();
        await f.expectState(moved: recorded);
        expect(await f.note.exists(), isFalse);
        await f.owner().recover();
        await f.expectState(moved: recorded);
      },
    );

    test(
      'folder interruption at ${step.name} is finished by its retry',
      () async {
        final engine = f.owner(interrupt: step);
        expect(await f.move(engine), isA<FolderMoveFailed>());
        expect(await f.move(engine), isA<FolderMoved>());
        await f.expectState(moved: true);
        expect(await f.move(engine), isA<FolderMoved>());
        await f.expectState(moved: true);
        expect(await f.note.exists(), isFalse);
      },
    );
  }

  for (final checkpoint in [
    FileRelocationStep.intent,
    FileRelocationStep.document,
  ]) {
    test(
      'a damaged kept-version folder after ${checkpoint.name} does not stop recovery',
      () async {
        expect(
          await f.move(f.owner(interrupt: checkpoint)),
          isA<FolderMoveFailed>(),
        );
        final last = f.disk.backupFolder(f.ref(f.from, _archived.last));
        await File(
          p.join(last.path, 'index.json'),
        ).writeAsString('malformed last backup');
        await File(
          p.join(last.path, 'foreign.txt'),
        ).writeAsString('preserve new backup material');
        await f.owner().recover();
        expect(await Directory(f.from).exists(), isFalse);
        expect(await f.note.exists(), isFalse);
        for (final entry in f.rows.entries) {
          expect(
            await f.participant(entry.key).readAsBytes(),
            utf8.encode(entry.value.replaceAll(f.from, f.to)),
          );
        }
        final moved = f.disk.backupFolder(f.ref(f.to, _archived.last));
        expect(
          await File(p.join(moved.path, 'index.json')).readAsString(),
          'malformed last backup',
        );
        expect(
          await File(p.join(moved.path, 'foreign.txt')).readAsString(),
          'preserve new backup material',
        );
      },
    );
  }

  for (final change in [
    'added',
    'changed PGN',
    'identical replacement',
    'changed sidecar',
  ]) {
    test(
      '$change after intent sets the stale record aside; moving again works',
      () async {
        expect(
          await f.move(f.owner(interrupt: FileRelocationStep.intent)),
          isA<FolderMoveFailed>(),
        );
        final chapter = File(p.join(f.from, 'Main.pgn'));
        switch (change) {
          case 'added':
            await File(p.join(f.from, 'new.txt')).writeAsString('external');
          case 'changed PGN':
            await chapter.writeAsString('external PGN');
          case 'identical replacement':
            await chapter.rename(p.join(f.disk.root.path, 'preserved.pgn'));
            await chapter.writeAsString(_current);
          case 'changed sidecar':
            await File(
              p.join(f.from, 'Nested', 'Artifacts', 'output.bin'),
            ).writeAsBytes([8, 9]);
        }
        final before = await f.readParticipants();
        await f.owner().recover();
        expect(await f.readParticipants(), before);
        expect(await f.note.exists(), isFalse);
        expect(f.quarantined(), hasLength(1));
        expect(await Directory(f.from).exists(), isTrue);
        expect(await Directory(f.to).exists(), isFalse);
        expect(await f.move(f.owner()), isA<FolderMoved>());
        expect(await Directory(f.from).exists(), isFalse);
        expect(await Directory(f.to).exists(), isTrue);
      },
    );
  }

  test(
    'a record made through a retargeted alias is set aside, not followed',
    () async {
      final alias = Link(p.join(f.disk.root.path, 'Documents-alias'));
      await alias.create(f.disk.documents.path);
      final engine = FileRelocations(
        documents: Directory(alias.path),
        support: f.disk.support,
        testHook: (step) async {
          if (step == FileRelocationStep.intent) throw StateError('interrupt');
        },
      );
      final from = p.join(alias.path, 'repertoires', 'Before');
      final to = p.join(alias.path, 'repertoires', 'After');
      expect(
        await engine.moveFolder(from, to, operationId: _id),
        isA<FolderMoveFailed>(),
      );
      final foreign = await Directory(
        p.join(f.disk.root.path, 'foreign'),
      ).create();
      await alias.delete();
      await alias.create(foreign.path);
      await f.owner().recover();
      await f.expectState(moved: false);
      expect(await foreign.list().toList(), isEmpty);
      expect(f.quarantined(), hasLength(1));
      await alias.delete();
      await alias.create(f.disk.documents.path);
      expect(await f.move(f.owner()), isA<FolderMoved>());
      await f.expectState(moved: true);
    },
  );

  test('a record with a foreign training root is set aside', () async {
    expect(
      await f.move(f.owner(interrupt: FileRelocationStep.intent)),
      isA<FolderMoveFailed>(),
    );
    final foreign = await Directory(
      p.join(f.disk.root.path, 'foreign'),
    ).create();
    final metadata = await f.metadata();
    metadata['trainingRoot'] = foreign.path;
    await f.note.writeAsString(jsonEncode(metadata));
    await f.owner().recover();
    expect(await f.note.exists(), isFalse);
    expect(f.quarantined(), hasLength(1));
    await f.expectState(moved: false);
  });

  test(
    'historical retry neither moves reused root nor restores later rows',
    () async {
      final engine = f.owner();
      expect(await f.move(engine), isA<FolderMoved>());
      await Directory(f.from).create();
      await File(p.join(f.from, 'replacement.txt')).writeAsString('new root');
      await f.participant(historyFile).writeAsString('later history');
      await f.books.writeAsString('{"later":true}');
      await engine.recover();
      expect(await f.move(engine), isA<FolderMoved>());
      expect(
        await File(p.join(f.from, 'replacement.txt')).readAsString(),
        'new root',
      );
      expect(await f.participant(historyFile).readAsString(), 'later history');
      expect(await f.books.readAsString(), '{"later":true}');
      expect(await f.note.exists(), isFalse);
    },
  );

  test(
    'folder id cannot be reused for another target or file operation',
    () async {
      final engine = f.owner();
      expect(await f.move(engine), isA<FolderMoved>());
      expect(
        await engine.moveFolder(f.from, '${f.to}-other', operationId: _id),
        isA<FolderMoveFailed>(),
      );
      final source = f.ref(f.to, 'Main.pgn');
      final revision = await f.disk.revisionOf(source);
      expect(
        await engine.move(
          source,
          f.ref(f.to, 'Renamed.pgn'),
          expected: revision,
          operationId: _id,
        ),
        isA<IoFailure>(),
      );
      await f.expectState(moved: true);
    },
  );

  for (final step in ['document', 'backups']) {
    test(
      'SIGKILL after $step finishes the folder move on the next start',
      () async {
        final harness = await Directory(
          p.join(Directory.current.path, '.dart_tool'),
        ).createTemp('folder-process-');
        addTearDown(() => harness.delete(recursive: true));
        final script = await File(
          p.join(harness.path, 'move.dart'),
        ).writeAsString(_driver);
        final child = await _start(script, f, step);
        addTearDown(child.close);
        expect(await Directory(f.from).exists(), isFalse);
        expect((await f.metadata())['state'], 'committing');
        expect(child.process.kill(ProcessSignal.sigkill), isTrue);
        await child.process.exitCode.timeout(const Duration(seconds: 10));
        await f.owner().recover();
        await f.expectState(moved: true);
        expect(await f.note.exists(), isFalse);
        await f.owner().recover();
        await f.expectState(moved: true);
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );
  }
}

final class _Fixture {
  _Fixture(this.disk);
  final StoreFixture disk;
  String get from => p.join(disk.documents.path, 'repertoires', 'Before');
  String get to => p.join(disk.documents.path, 'repertoires', 'After');
  File get note =>
      File(p.join(disk.support.path, 'relocation-writes', '$_id.json'));
  File get books => File(p.join(disk.support.path, 'books.json'));
  File participant(String name) => File(p.join(disk.documents.path, name));
  DocumentRef ref(String root, String name) => DocumentRef(p.join(root, name));
  FileRelocations owner({FileRelocationStep? interrupt}) {
    var interrupted = false;
    return FileRelocations(
      documents: disk.documents,
      support: disk.support,
      testHook: interrupt == null
          ? null
          : (step) async {
              if (step == interrupt && !interrupted) {
                interrupted = true;
                throw StateError('interrupt ${step.name}');
              }
            },
    );
  }

  List<File> quarantined() {
    final folder = Directory(p.join(disk.support.path, 'recovery-quarantine'));
    if (!folder.existsSync()) return const [];
    return folder.listSync(recursive: true).whereType<File>().toList();
  }

  Future<FolderMoveResult> move(FileRelocations engine) =>
      engine.moveFolder(from, to, operationId: _id);
  Future<Map<String, Object?>> metadata() async =>
      jsonDecode(await note.readAsString()) as Map<String, Object?>;
  Map<String, String> get rows => _rows(from);
  String get bookText => _bookText();
  Map<String, List<int>> get tree => {
    for (final path in _archived) path: utf8.encode(_current),
    'Nested/raw_games.pgn': utf8.encode('1. c4 *'),
    'Nested/Artifacts/output.bin': [0, 255, 127, 10],
    'Nested/Artifacts/manifest.json': utf8.encode('{"generation":"preserve"}'),
  };

  static Future<_Fixture> create() async {
    final f = _Fixture(await StoreFixture.create());
    for (final name in _archived) {
      final ref = f.ref(f.from, name);
      final before = await f.disk.put(ref, _old);
      expect(await f.disk.replace(ref, _current, before), isA<Saved>());
    }
    await Directory(p.join(f.from, 'Nested', 'Artifacts')).create();
    await Directory(p.join(f.from, 'Empty')).create();
    for (final entry in f.tree.entries) {
      if (!_archived.contains(entry.key)) {
        await File(p.join(f.from, entry.key)).writeAsBytes(entry.value);
      }
    }
    for (final entry in f.rows.entries) {
      await f.participant(entry.key).writeAsString(entry.value);
    }
    await f.books.writeAsString(f.bookText);
    final archive = BackupArchive(
      Directory(p.join(f.disk.support.path, 'backups')),
    );
    final target = f.ref(f.to, 'Main.pgn');
    expect(
      await archive.record(
        id: backupId(p.relative(target.path, from: f.disk.documents.path)),
        documentPath: target.path,
        bytes: utf8.encode(_orphan),
        hash: sha256.convert(utf8.encode(_orphan)).toString(),
      ),
      isA<BackupRecorded>(),
    );
    return f;
  }

  Future<Map<String, List<int>>> readParticipants() async => {
    for (final name in rows.keys) name: await participant(name).readAsBytes(),
    'books': await books.readAsBytes(),
  };

  Future<void> expectState({required bool moved}) async {
    final root = moved ? to : from;
    expect(await Directory(moved ? from : to).exists(), isFalse);
    for (final entry in tree.entries) {
      expect(await File(p.join(root, entry.key)).readAsBytes(), entry.value);
    }
    expect(await Directory(p.join(root, 'Empty')).list().toList(), isEmpty);
    for (final entry in rows.entries) {
      expect(
        await participant(entry.key).readAsBytes(),
        utf8.encode(moved ? entry.value.replaceAll(from, to) : entry.value),
      );
    }
    expect(
      await books.readAsString(),
      moved ? bookText.replaceAll('Before', 'After') : bookText,
    );
    for (final name in _archived) {
      expect(disk.keptTexts(ref(root, name)), [_old]);
      if (moved) {
        expect(disk.backupFolder(ref(from, name)).existsSync(), isFalse);
      }
    }
    final target = ref(to, 'Main.pgn');
    if (!moved) {
      expect(disk.keptTexts(target), [_orphan]);
      return;
    }
    // The history that already held the target's id belonged to another
    // chapter; it is offered back as a deleted chapter of the moved folder.
    final listing =
        await listDeleted(Directory(p.join(disk.documents.path, 'repertoires')))
            as DeletedChapters;
    final displaced = listing.chapters.singleWhere(
      (chapter) => chapter.name == 'Main' && chapter.folder == to,
    );
    expect(await File(displaced.path).readAsString(), _orphan);
    expect(disk.keptTexts(DocumentRef(displaced.path)), [_orphan]);
  }
}

Map<String, String> _rows(String root) => {
  reviewsFile:
      '\ufeffrepertoire_id,line_id,line_name,difficulty,interval_days,due_utc,last_rating,last_reviewed_utc,pass_count,fail_count,excluded\r\n'
      '${p.join(root, 'Main.pgn')},line,Mainline,2.5,1,2026-09-01T00:00:00Z,good,2026-08-31T00:00:00Z,2,0,false\r\n',
  streaksFile:
      'repertoire_id,line_id,move_index,correct_streak,learned\n${p.join(root, 'Nested', 'Upper.PGN')},line,1,2,true\n',
  historyFile:
      'repertoire_id,line_id,timestamp_utc,rating,had_mistake,session_type\n${p.join(root, 'Nested', '.cap-pgn-history', '1-a-Old.pgn')},line,2026-08-31T00:00:00Z,good,false,trainer\n',
  attemptsFile:
      '${jsonEncode({
        'repertoireId': p.join(root, 'Main.pgn'),
        'future': [1, 'two'],
      })}\n'
      '{ "repertoireId": "/unrelated.pgn", "unknown": 17 }\n',
};

String _bookText() => jsonEncode({
  'version': 1,
  'future': {'keep': true},
  'books': [
    {
      'id': 'book',
      'name': 'Book',
      'repertoires': ['Before', 'Before/Nested'],
      'chapters': [
        {'path': 'Before/Main.pgn', 'section': 'Main', 'annotation': 7},
        {'path': 'Before/Nested/Upper.PGN', 'section': null},
      ],
    },
  ],
});

Future<_Child> _start(File script, _Fixture f, String checkpoint) async {
  final process = await Process.start('dart', [
    'run',
    '--packages=${p.join(Directory.current.path, '.dart_tool', 'package_config.json')}',
    script.path,
    f.disk.documents.path,
    f.disk.support.path,
    f.from,
    f.to,
    checkpoint,
  ], workingDirectory: Directory.current.path);
  final ready = Completer<void>();
  final diagnostics = StringBuffer();
  final output = process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
        if (line == 'checkpoint durable' && !ready.isCompleted) {
          ready.complete();
        }
        diagnostics.writeln(line);
      });
  final errors = process.stderr
      .transform(utf8.decoder)
      .listen(diagnostics.write);
  unawaited(
    process.exitCode.then((code) {
      if (!ready.isCompleted) {
        ready.completeError(StateError('Child exited $code: $diagnostics'));
      }
    }),
  );
  final child = _Child(process, output, errors);
  try {
    await ready.future.timeout(const Duration(seconds: 60));
    return child;
  } on Object {
    await child.close();
    rethrow;
  }
}

final class _Child {
  _Child(this.process, this.output, this.errors);
  final Process process;
  final StreamSubscription<String> output;
  final StreamSubscription<String> errors;
  Future<void> close() async {
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;
    await output.cancel();
    await errors.cancel();
  }
}

const _driver = r'''
import 'dart:convert';
import 'dart:io';
import 'package:chess_auto_prep/v2/storage/file_relocation.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
Future<void> main(List<String> args) async {
  final owner = FileRelocations(documents: Directory(args[0]), support: Directory(args[1]),
    testHook: (step) async {
      if (step.name != args[4]) return;
      stdout.writeln('checkpoint durable');
      await stdin.transform(utf8.decoder).transform(const LineSplitter()).first;
    });
  final result = await owner.moveFolder(args[2], args[3], operationId: 'folder-recovery');
  if (result is! FolderMoved) throw StateError('Move failed before checkpoint: $result');
}
''';

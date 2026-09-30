import 'dart:io';

import 'package:chess_auto_prep/features/study/studies.dart';
import 'package:chess_auto_prep/net/lichess_studies.dart';
import 'package:chess_auto_prep/storage/pgn_file_import.dart';
import 'package:chess_auto_prep/storage/pgn_file_store.dart';
import 'package:chess_auto_prep/storage/recovery_gate.dart';
import 'package:chess_auto_prep/storage/study_files.dart';
import 'package:chess_auto_prep/workspace/document_saver.dart';
import 'package:chess_auto_prep/workspace/document_session.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import '../support/lock_path.dart';
import '../support/study_fixture.dart' show ScriptedLichess;
import '../support/viewer_fixture.dart' show ScriptedPicker;

void main() {
  late Directory root;
  late Directory documents;
  late NativePgnFileImport import;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('v2-import-');
    documents = Directory(p.join(root.path, 'Documents'));
    await documents.create();
    import = NativePgnFileImport(
      recovery: RecoveryGate(
        documents: documents,
        support: Directory(p.join(root.path, 'Support')),
      ),
      documents: documents.path,
      into: p.join(documents.path, 'pgn_collections'),
    );
  });

  tearDown(() => root.delete(recursive: true));

  test('a file inside Documents is opened where it is', () async {
    final path = p.join(documents.path, 'repertoires', 'KID', 'Main.pgn');
    final result = await import.insideDocuments(path);
    expect(result, isA<FileToOpen>());
    expect((result as FileToOpen).path, path);
    expect(result.copied, isFalse);
  });

  test(
    'a file outside is copied into pgn_collections and the copy opened',
    () async {
      final downloads = Directory(p.join(root.path, 'Downloads'));
      await downloads.create();
      final source = File(p.join(downloads.path, 'course.pgn'));
      await source.writeAsString('[Event "A"]\n\n1. e4 *\n');
      final result = await import.insideDocuments(source.path) as FileToOpen;
      expect(result.copied, isTrue);
      expect(
        result.path,
        p.join(documents.path, 'pgn_collections', 'course.pgn'),
      );
      expect(
        await File(result.path).readAsString(),
        '[Event "A"]\n\n1. e4 *\n',
      );
      expect(await source.exists(), isTrue, reason: 'the original is left');
    },
  );

  test('a second copy of the same name sits beside the first', () async {
    final source = File(p.join(root.path, 'course.pgn'));
    await source.writeAsString('1. e4 *\n');
    final first = await import.insideDocuments(source.path) as FileToOpen;
    await source.writeAsString('1. d4 *\n');
    final second = await import.insideDocuments(source.path) as FileToOpen;
    expect(p.basename(second.path), 'course (2).pgn');
    expect(await File(first.path).readAsString(), '1. e4 *\n');
    expect(await File(second.path).readAsString(), '1. d4 *\n');
  });

  test('a file that is not there cannot be copied, and says so', () async {
    final result = await import.insideDocuments(p.join(root.path, 'no.pgn'));
    expect(result, isA<ImportFailed>());
  });

  test('a copy waits while another writer holds pgn_collections', () async {
    final source = File(p.join(root.path, 'course.pgn'));
    await source.writeAsString('1. e4 *\n');
    final into = Directory(p.join(documents.path, 'pgn_collections'));
    await into.create();
    // A save of a file already in the folder, by this app or the old one:
    // it sweeps staged copies before writing its own.
    final other = sqlite3.open(await lockPathOf(into));
    other.execute('PRAGMA busy_timeout = 0');
    other.execute('BEGIN IMMEDIATE');
    var done = false;
    final copied = import
        .insideDocuments(source.path)
        .whenComplete(() => done = true);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(done, isFalse, reason: 'the other writer still holds the folder');
    expect(await into.list().toList(), isEmpty);
    other
      ..execute('ROLLBACK')
      ..close();
    final result = await copied as FileToOpen;
    expect(await File(result.path).readAsString(), '1. e4 *\n');
  });

  test('a name taken by something that is not a file is passed over', () async {
    final source = File(p.join(root.path, 'course.pgn'));
    await source.writeAsString('1. e4 *\n');
    final into = p.join(documents.path, 'pgn_collections');
    // Not a file, so a look for a file there finds nothing, but the name is
    // still taken when the copy is put in place.
    await Directory(p.join(into, 'course.pgn')).create(recursive: true);
    final result = await import.insideDocuments(source.path) as FileToOpen;
    expect(p.basename(result.path), 'course (2).pgn');
    expect(await File(result.path).readAsString(), '1. e4 *\n');
  });

  test(
    'reading a picked file writes nothing, and keeps its encoding',
    () async {
      final downloads = Directory(p.join(root.path, 'Downloads'));
      await downloads.create();
      final plain = File(p.join(downloads.path, 'plain.pgn'));
      await plain.writeAsString('[Event "A"]\n\n1. e4 *\n');
      final latin = File(p.join(downloads.path, 'latin.pgn'));
      await latin.writeAsBytes([...'[Event "Caf'.codeUnits, 0xE9, 0x22, 0x5D]);
      final read = await import.read(plain.path) as PickedText;
      expect(read.text, '[Event "A"]\n\n1. e4 *\n');
      expect(read.foreignEncoding, isNull);
      final guessed = await import.read(latin.path) as PickedText;
      expect(guessed.text, '[Event "Caf\u00e9"]');
      expect(guessed.foreignEncoding, contains('not UTF-8'));
      expect(
        await import.read(p.join(downloads.path, 'no.pgn')),
        isA<PickedUnread>(),
      );
      expect(await Directory(import.into).exists(), isFalse);
    },
  );

  test('importing a study leaves no copy in pgn_collections', () async {
    final downloads = Directory(p.join(root.path, 'Downloads'));
    await downloads.create();
    final course = File(p.join(downloads.path, 'course.pgn'));
    final store = PgnFileStore(
      documents: documents,
      support: Directory(p.join(root.path, 'Support')),
    );
    final studiesRoot = p.join(documents.path, 'studies');
    final saver = DocumentSaver(store, delay: Duration.zero);
    final session = DocumentSession(store, saver);
    final studies = Studies(
      files: StudyDirectory(Directory(studiesRoot), recovery: store.recovery),
      documents: store,
      session: session,
      picker: ScriptedPicker(course.path),
      importer: NativePgnFileImport(
        recovery: store.recovery,
        documents: documents.path,
        into: p.join(documents.path, 'pgn_collections'),
      ),
      saver: saver,
      lichess: ScriptedLichess(
        const StudyNotFetched(StudyFetchProblem.unreachable),
      ),
      root: studiesRoot,
    );
    addTearDown(() {
      studies.dispose();
      session.dispose();
      saver.dispose();
    });

    await course.writeAsString('not a game\n');
    expect(await studies.importPgn(), isA<StudyProblem>());
    const text = '[Event "Course"]\n\n1. e4 e5 *\n';
    await course.writeAsString(text);
    expect(await studies.importPgn(), isA<StudyDone>());

    final collections = Directory(p.join(documents.path, 'pgn_collections'));
    expect(
      await collections.exists() ? await collections.list().toList() : [],
      isEmpty,
    );
    final filed = await Directory(studiesRoot).list().toList();
    expect(filed.map((entry) => p.basename(entry.path)), ['course.pgn']);
    expect(await File(filed.single.path).readAsString(), text);
  });
}

@TestOn('linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/features/library/library.dart';
import 'package:chess_auto_prep/v2/features/library/library_state.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/file_relocation.dart';
import 'package:chess_auto_prep/v2/storage/pending_writes.dart';
import 'package:chess_auto_prep/v2/storage/pgn_file_store.dart';
import 'package:chess_auto_prep/v2/workspace/document_saver.dart';
import 'package:chess_auto_prep/v2/workspace/document_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../storage/store_fixture.dart';
import '../support/viewer_fixture.dart';

void main() {
  for (final phase in [
    FileRelocationStep.intent,
    FileRelocationStep.document,
  ]) {
    test(
      'import retry preserves its accepted course after ${phase.name}',
      () async {
        final disk = await StoreFixture.create();
        final root = p.join(disk.documents.path, 'repertoires');
        var interrupted = true;
        final store = PgnFileStore(
          documents: disk.documents,
          support: disk.support,
          relocationHook: (step) async {
            if (interrupted && step == phase)
              throw StateError('Interrupted import');
          },
        );
        final pending = PendingWrites();
        final saver = DocumentSaver(store, pendingWrites: pending);
        final session = DocumentSession(store, saver);
        final library = Library(
          files: ChapterDirectory(Directory(root), recovery: store.recovery),
          documents: store,
          saver: saver,
          session: session,
          picker: ScriptedPicker(),
          root: root,
          pendingWrites: pending,
        );
        addTearDown(() async {
          library.dispose();
          session.dispose();
          saver.dispose();
          await disk.dispose();
        });

        final failed =
            await library.importText(
                  '[Event "Imported"]\n\n1. e4 e5 *\n',
                  name: 'Imported',
                )
                as LibraryFailure;
        expect(failed.retry, isNotNull);
        final notes = Directory(p.join(disk.support.path, 'relocation-writes'));
        final journal = notes.listSync().whereType<File>().single;
        final manifest =
            jsonDecode(await journal.readAsString()) as Map<String, Object?>;
        final acceptedId = manifest['id'];
        final from = manifest['from']! as String;
        final to = manifest['to']! as String;
        expect(
          await Directory(from).exists() || await Directory(to).exists(),
          isTrue,
        );
        expect(await pending.settle(), isNotNull);

        interrupted = false;
        // Recovery may run before the UI retry; its retained id still names the
        // original import, even though staging has already moved out of the way.
        await pending.retry(store);
        final added = await failed.retry!() as LibraryAdded;
        expect(added.first.path, p.join(root, 'Imported', 'Main.pgn'));
        expect(added.chapters, 1);
        expect(added.lines, 1);
        final content = await File(added.first.path).readAsString();
        expect(content, contains('e4 e5'));
        expect(await failed.retry!(), same(added));
        expect(await File(added.first.path).readAsString(), content);
        expect(await Directory(from).exists(), isFalse);
        expect(notes.listSync().whereType<File>(), hasLength(1));
        final completed =
            jsonDecode(await journal.readAsString()) as Map<String, Object?>;
        expect(completed['id'], acceptedId);
        expect(completed['state'], 'complete');
        expect(await pending.settle(), isNull);
        expect(library.repertoires.map((folder) => folder.name), ['Imported']);
      },
    );
  }
}

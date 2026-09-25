@TestOn('linux')
library;

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
      'an import interrupted at ${phase.name} can simply be made again',
      () async {
        final disk = await StoreFixture.create();
        final root = p.join(disk.documents.path, 'repertoires');
        var interrupted = true;
        final store = PgnFileStore(
          documents: disk.documents,
          support: disk.support,
          relocationHook: (step) async {
            if (interrupted && step == phase) {
              throw StateError('Interrupted import');
            }
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

        final failed = await library.importText(
          '[Event "Imported"]\n\n1. e4 e5 *\n',
          name: 'Imported',
        );
        expect(failed, isA<LibraryFailure>());
        expect(library.busy, isFalse);

        interrupted = false;
        // Nothing is waiting to be retried: importing again is the way on,
        // and it ends with the course in the list exactly once.
        final again = await library.importText(
          '[Event "Imported"]\n\n1. e4 e5 *\n',
          name: 'Imported',
        );
        expect(again, isA<LibraryAdded>());
        await library.refresh();
        final added = library.repertoires
            .expand((folder) => folder.chapters)
            .map((chapter) => chapter.path)
            .toList();
        expect(added, isNotEmpty);
        for (final path in added) {
          expect(await File(path).readAsString(), contains('e4 e5'));
        }
        final staging = Directory(root).listSync().where(
          (entry) => p.basename(entry.path).startsWith('.import-'),
        );
        expect(staging, isEmpty, reason: 'no staging folder is left behind');
      },
    );
  }
}

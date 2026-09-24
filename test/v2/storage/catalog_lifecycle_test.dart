import 'dart:io';

import 'package:chess_auto_prep/v2/storage/book_list.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/document_repository.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/workspace/document_projection.dart'
    as projection;
import 'package:chess_auto_prep/v2/workspace/repertoire_catalog.dart';
import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/pgn/chapter_edit.dart';
import 'package:chess_auto_prep/v2/chess/pgn/chapter_sections.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/scripted_files.dart';
import '../support/scripted_store.dart';
import 'store_fixture.dart';

void main() {
  test(
    'a failed mutation publishes nothing; concurrent commits survive coalescing',
    () async {
      final disk = ScriptedDocumentStore();
      final repo = DocumentRepository(disk);
      final files = ScriptedFiles();
      final catalog = RepertoireCatalog(
        files: files,
        documents: repo,
        root: '/repertoires',
      );
      addTearDown(repo.dispose);
      addTearDown(catalog.dispose);
      await catalog.refresh();
      var notifications = 0;
      catalog.addListener(() => notifications++);
      const a = DocumentRef('/repertoires/A/Main.pgn');
      const b = DocumentRef('/repertoires/B/Main.pgn');
      files.hold = true;
      await repo.create(a, '*');
      await repo.create(b, '*');
      final done = catalog.synchronize();
      files.releaseNext();
      await pumpEventQueue();
      files.hold = false;
      files.releaseNext();
      await done;
      expect(notifications, 1);
      expect(catalog.changes.map((change) => change.path), [a.path, b.path]);
      expect(await repo.create(a, '*'), isA<Collision>());
      await pumpEventQueue();
      expect(notifications, 1);
    },
  );

  test(
    'named singleton retains book membership and rejects a stale sibling ref',
    () async {
      const text =
          '[Event "A"]\n[ChapterName "A"]\n\n1. e4 *\n\n[Event "B"]\n[ChapterName "B"]\n\n1. d4 *\n';
      final file = parseChapter(name: 'Course', text: text);
      final changed = sectionRemoved(file, 'A') as ChapterEdited;
      final kept = writeChapter(changed.chapter);
      expect(sectionsInText(kept), ['B']);
      final book = Book(
        id: 'b',
        name: 'B',
        chapters: {BookChapter('Course.pgn', 'B')},
      );
      expect(book.includes('Course.pgn', sectionsInText(kept).single), isTrue);
      final store = ScriptedDocumentStore();
      const path = '/repertoires/Course.pgn';
      store.documents[const DocumentRef(path)] = Opened(
        kept,
        scriptedRevision(kept),
      );
      expect(
        await projection.readDocument(store, ChapterRef.at(path, section: 'A')),
        isA<projection.DocumentUnread>(),
      );
      final shown =
          await projection.readDocument(
                store,
                ChapterRef.at(path, section: 'B'),
              )
              as projection.DocumentShown;
      expect(shown.chapter.name, 'B');
      expect(shown.chapter.lines, hasLength(1));
    },
  );

  test(
    'legacy files migrate guardedly, nested files follow rename and recovery',
    () async {
      final disk = await StoreFixture.create();
      addTearDown(disk.dispose);
      final root = Directory(p.join(disk.documents.path, 'repertoires'));
      final flat = disk.ref('repertoires/Legacy.pgn');
      await disk.put(flat, '[Event "Legacy"]\n\n1. e4 *\n');
      final nested = disk.ref('repertoires/KID/Week 1/Main.pgn');
      final revision = await disk.put(nested, '[Event "Nested"]\n\n1. d4 *\n');
      await disk.edit(nested, '[Event "Nested"]\n\n1. d4 d5 *\n', revision);
      final files = ChapterDirectory(
        root,
        documents: disk.store,
        recovery: disk.store.recovery,
      );
      final listing = await files.list() as Repertoires;
      expect(listing.folders.map((f) => f.name), ['KID', 'Legacy']);
      expect(listing.folders.first.chapters.single.repertoire, 'KID');
      expect(
        listing.folders.last.chapters.single.path,
        p.join(root.path, 'Legacy', 'Main.pgn'),
      );
      expect(await File(flat.path).exists(), isFalse);
      const book = Book(id: 'k', name: 'KID', repertoires: {'KID'});
      expect(book.includes('KID/Week 1/Main.pgn', null), isTrue);
      final from = p.join(root.path, 'KID');
      final to = p.join(root.path, 'Renamed');
      expect(await disk.store.moveFolder(from, to), isA<FolderMoved>());
      final moved = DocumentRef(p.join(to, 'Week 1', 'Main.pgn'));
      expect(
        disk.keptVersions(moved),
        isNotEmpty,
        reason: 'nested history follows the move',
      );
      final opened = await disk.store.open(moved) as Opened;
      expect(
        await disk.store.delete(moved, expected: opened.revision),
        isA<Deleted>(),
      );
      final deleted = await files.deleted() as DeletedChapters;
      expect(deleted.chapters.single.folder, p.dirname(moved.path));
      final recovery = DocumentRef(deleted.chapters.single.path);
      final read = await disk.store.open(recovery) as Opened;
      expect(
        await disk.store.move(recovery, moved, expected: read.revision),
        isA<Moved>(),
      );
      expect((await disk.store.open(moved) as Opened).text, contains('d4 d5'));
    },
  );
}

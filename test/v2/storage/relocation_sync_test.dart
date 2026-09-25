@TestOn('linux || mac-os')
library;

import 'dart:io';

import 'package:chess_auto_prep/v2/storage/backups.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/document_relocation.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/storage/relocation_notes.dart';
import 'package:chess_auto_prep/v2/storage/training_records.dart' as training;
import 'package:document_file_io/document_file_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'store_fixture.dart';

void main() {
  late StoreFixture fixture;
  late PendingRepoints pending;
  late RelocationNotes notes;
  late DocumentRelocation relocation;
  late List<String> flushed;
  String? failAt;

  setUp(() async {
    fixture = await StoreFixture.create();
    pending = PendingRepoints(fixture.support, documents: fixture.documents);
    flushed = [];
    failAt = null;
    notes = RelocationNotes(
      notes: pending,
      records: training.TrainingRecords(fixture.documents),
      synchronize: (path) async {
        flushed.add(path);
        if (path == failAt) {
          throw FileSystemException('injected flush failure', path);
        }
        await syncDirectory(path);
      },
    );
    relocation = DocumentRelocation(
      documents: fixture.documents,
      backups: BackupArchive(
        Directory(p.join(fixture.support.path, 'backups')),
      ),
      notes: notes,
    );
  });
  tearDown(() => fixture.dispose());

  File getRows() =>
      File(p.join(fixture.documents.path, 'repertoire_move_progress.csv'));
  Future<void> rowsFor(DocumentRef ref) => getRows().writeAsString(
    'repertoire_id,line_id,move_index,correct_streak,learned\n'
    '${ref.path},line_1,4,2,true\n',
  );

  for (final operation in ['move', 'folder', 'delete']) {
    for (final endpoint in ['source', 'destination', 'ancestor']) {
      test('$operation retains its note when $endpoint flush fails', () async {
        final from = fixture.ref('repertoires/Before/Main.pgn');
        final to = fixture.ref('repertoires/After/Main.pgn');
        final revision = await fixture.put(from, oneGame('1. d4'));
        await rowsFor(from);
        final sourceParent = operation == 'folder'
            ? p.dirname(p.dirname(from.path))
            : p.dirname(from.path);
        final destinationParent = switch (operation) {
          'folder' => p.join(fixture.documents.path, 'nested'),
          'delete' => p.join(p.dirname(from.path), recoveryFolder),
          _ => p.dirname(to.path),
        };
        if (operation == 'folder') await Directory(destinationParent).create();
        failAt = switch (endpoint) {
          'source' => sourceParent,
          'destination' => destinationParent,
          _ => fixture.documents.path,
        };
        final Object result = switch (operation) {
          'folder' => await relocation.moveFolder(
            p.dirname(from.path),
            p.join(destinationParent, 'After'),
          ),
          'delete' => await relocation.delete(from, expected: revision),
          _ => await relocation.move(from, to, expected: revision),
        };
        expect(
          result,
          operation == 'folder' ? isA<FolderMoveFailed>() : isA<IoFailure>(),
        );
        final owed = await pending.read();
        expect(owed, hasLength(1));
        expect(await File(from.path).exists(), isFalse);
        final movedPath = operation == 'folder'
            ? p.join(owed.single.to, 'Main.pgn')
            : owed.single.to;
        expect(await File(movedPath).readAsString(), oneGame('1. d4'));
        expect(await getRows().readAsString(), contains(from.path));
        await expectLater(
          notes.finishOwed(),
          throwsA(isA<FileSystemException>()),
        );
        expect(await pending.read(), hasLength(1));
        failAt = null;
        flushed.clear();
        await notes.finishOwed();
        expect(
          flushed,
          containsAll([
            sourceParent,
            destinationParent,
            fixture.documents.path,
          ]),
        );
        expect(await pending.read(), isEmpty);
        expect(await getRows().readAsString(), contains(movedPath));
        final committedRows = await getRows().readAsString();
        await notes.finishOwed();
        expect(await getRows().readAsString(), committedRows);
      });
    }
  }

  test('a configured Documents alias still permits a confirmed move', () async {
    final ref = fixture.ref('repertoires/Before/Main.pgn');
    final revision = await fixture.put(ref, oneGame('1. d4'));
    final alias = p.join(fixture.root.path, 'documents-alias');
    await Link(alias).create(fixture.documents.path);
    final documents = Directory(alias);
    final relocation = DocumentRelocation(
      documents: documents,
      backups: BackupArchive(
        Directory(p.join(fixture.support.path, 'backups')),
      ),
      notes: RelocationNotes(
        notes: PendingRepoints(fixture.support, documents: documents),
        records: training.TrainingRecords(documents),
      ),
    );
    final from = DocumentRef(
      p.join(alias, 'repertoires', 'Before', 'Main.pgn'),
    );
    expect(
      await relocation.rename(from, 'After.pgn', expected: revision),
      isA<Moved>(),
    );
    expect(await pending.read(), isEmpty);
  });

  test('new metadata ancestry must flush before a move may start', () async {
    final from = fixture.ref('repertoires/Before/Main.pgn');
    final to = fixture.ref('repertoires/Before/After.pgn');
    final revision = await fixture.put(from, oneGame('1. d4'));
    final support = Directory(
      p.join(fixture.root.path, 'new', 'nested', 'Support'),
    );
    final flushed = <String>[];
    var blocked = true;
    final pending = PendingRepoints(
      support,
      documents: fixture.documents,
      synchronize: (path) async {
        flushed.add(path);
        if (blocked && path == fixture.root.path) {
          throw FileSystemException('injected metadata flush failure', path);
        }
        await syncDirectory(path);
      },
    );
    final relocation = DocumentRelocation(
      documents: fixture.documents,
      backups: BackupArchive(Directory(p.join(support.path, 'backups'))),
      notes: RelocationNotes(
        notes: pending,
        records: training.TrainingRecords(fixture.documents),
      ),
    );
    expect(
      await relocation.move(from, to, expected: revision),
      isA<IoFailure>(),
    );
    expect(await File(from.path).exists(), isTrue);
    expect(await File(to.path).exists(), isFalse);
    expect(await pending.read(), isEmpty);
    blocked = false;
    flushed.clear();
    expect(await relocation.move(from, to, expected: revision), isA<Moved>());
    expect(
      flushed,
      containsAllInOrder([
        p.join(support.path, 'unfinished-moves'),
        support.path,
        p.dirname(support.path),
        p.join(fixture.root.path, 'new'),
        fixture.root.path,
      ]),
    );
  });

  test('a cancelled move flush failure retains its recovery note', () async {
    final from = fixture.ref('repertoires/Before/Main.pgn');
    final to = fixture.ref('repertoires/Absent/Nested/Main.pgn');
    await fixture.put(from, oneGame('1. d4'));
    final identity = (await observeFile(from.path)).identity!;
    await pending.record(
      'cancelled',
      from: from.path,
      to: to.path,
      identity: identity,
      folder: false,
    );
    failAt = p.dirname(from.path);
    await expectLater(notes.finishOwed(), throwsA(isA<FileSystemException>()));
    expect(await pending.read(), hasLength(1));
    failAt = null;
    await notes.finishOwed();
    expect(await pending.read(), isEmpty);
    expect(await File(from.path).exists(), isTrue);
    expect(flushed, contains(fixture.documents.path));
  });
}

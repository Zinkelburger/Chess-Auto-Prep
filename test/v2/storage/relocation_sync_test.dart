@TestOn('linux || mac-os')
library;

import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/storage/backups.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/document_relocation.dart';
import 'package:chess_auto_prep/v2/storage/file_relocation.dart';
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

  for (final endpoint in ['source', 'destination', 'ancestor']) {
    test('folder retains its note when $endpoint flush fails', () async {
      final from = fixture.ref('repertoires/Before/Main.pgn');
      await fixture.put(from, oneGame('1. d4'));
      await rowsFor(from);
      final sourceParent = p.dirname(p.dirname(from.path));
      final destinationParent = p.join(fixture.documents.path, 'nested');
      await Directory(destinationParent).create();
      failAt = switch (endpoint) {
        'source' => sourceParent,
        'destination' => destinationParent,
        _ => fixture.documents.path,
      };
      expect(
        await relocation.moveFolder(
          p.dirname(from.path),
          p.join(destinationParent, 'After'),
        ),
        isA<FolderMoveFailed>(),
      );
      final owed = await pending.read();
      expect(owed, hasLength(1));
      final movedPath = p.join(owed.single.to, 'Main.pgn');
      expect(await File(from.path).exists(), isFalse);
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
        containsAll([sourceParent, destinationParent, fixture.documents.path]),
      );
      expect(await pending.read(), isEmpty);
      expect(await getRows().readAsString(), contains(movedPath));
      final committedRows = await getRows().readAsString();
      await notes.finishOwed();
      expect(await getRows().readAsString(), committedRows);
    });
  }

  for (final operation in ['move', 'rename', 'delete']) {
    for (final endpoint in ['source', 'destination', 'ancestor']) {
      test(
        '$operation retains committing journal when $endpoint flush fails',
        () async {
          const id = '1780000000000000-f1';
          final from = fixture.ref('repertoires/Before/Main.pgn');
          final to = fixture.ref(
            operation == 'move'
                ? 'repertoires/After/Main.pgn'
                : operation == 'delete'
                ? 'repertoires/Before/.cap-pgn-history/$id-Main.pgn'
                : 'repertoires/Before/Renamed.pgn',
          );
          final revision = await fixture.put(from, oneGame('1. d4'));
          await rowsFor(from);
          final before = await getRows().readAsBytes();
          final failedPath = switch (endpoint) {
            'source' => p.dirname(from.path),
            'destination' => p.dirname(to.path),
            _ => fixture.documents.path,
          };
          final owner = FileRelocations(
            documents: fixture.documents,
            support: fixture.support,
            testHook: (step) async {
              if (step == FileRelocationStep.intent) failAt = failedPath;
            },
            synchronize: (path) async {
              flushed.add(path);
              if (path == failAt && !await File(from.path).exists()) {
                throw FileSystemException('injected flush failure', path);
              }
              await syncDirectory(path);
            },
          );
          Future<Object> run() async => operation == 'delete'
              ? owner.delete(from, expected: revision, operationId: id)
              : owner.move(from, to, expected: revision, operationId: id);
          expect(await run(), isA<IoFailure>());
          final note = File(
            p.join(fixture.support.path, 'relocation-writes', '$id.json'),
          );
          final committing = await note.readAsBytes();
          expect(jsonDecode(utf8.decode(committing))['state'], 'committing');
          expect(await File(from.path).exists(), isFalse);
          expect(await File(to.path).readAsString(), oneGame('1. d4'));
          expect(await getRows().readAsBytes(), before);
          await expectLater(owner.recover(), throwsA(isA<RecoveryRequired>()));
          expect(await note.readAsBytes(), committing);
          expect(await getRows().readAsBytes(), before);
          failAt = null;
          flushed.clear();
          await owner.recover();
          expect(
            flushed,
            containsAll([
              p.dirname(from.path),
              p.dirname(to.path),
              fixture.documents.path,
            ]),
          );
          expect(jsonDecode(await note.readAsString())['state'], 'complete');
          expect(await getRows().readAsString(), contains(to.path));
          final committed = await getRows().readAsBytes();
          expect(
            await run(),
            operation == 'delete' ? isA<Deleted>() : isA<Moved>(),
          );
          expect(await getRows().readAsBytes(), committed);
        },
      );
    }
  }

  test('a configured Documents alias still permits a confirmed move', () async {
    final ref = fixture.ref('repertoires/Before/Main.pgn');
    final revision = await fixture.put(ref, oneGame('1. d4'));
    final alias = p.join(fixture.root.path, 'documents-alias');
    await Link(alias).create(fixture.documents.path);
    final documents = Directory(alias);
    final relocation = FileRelocations(
      documents: documents,
      support: fixture.support,
    );
    final from = DocumentRef(
      p.join(alias, 'repertoires', 'Before', 'Main.pgn'),
    );
    expect(
      await relocation.move(
        from,
        DocumentRef(p.join(p.dirname(from.path), 'After.pgn')),
        expected: revision,
        operationId: 'alias-move',
      ),
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
    final relocation = FileRelocations(
      documents: fixture.documents,
      support: support,
      synchronize: (path) async {
        flushed.add(path);
        if (blocked && path == fixture.root.path) {
          throw FileSystemException('injected metadata flush failure', path);
        }
        await syncDirectory(path);
      },
    );
    expect(
      await relocation.move(
        from,
        to,
        expected: revision,
        operationId: 'new-ancestry',
      ),
      isA<IoFailure>(),
    );
    expect(await File(from.path).exists(), isTrue);
    expect(await File(to.path).exists(), isFalse);
    final journal = Directory(p.join(support.path, 'relocation-writes'));
    expect(await journal.list().toList(), isEmpty);
    // The first attempt created the ancestors; their existence is not proof
    // that their parent entries were durably synchronized.
    expect(
      await relocation.move(
        from,
        to,
        expected: revision,
        operationId: 'new-ancestry',
      ),
      isA<IoFailure>(),
    );
    expect(await File(from.path).exists(), isTrue);
    expect(await File(to.path).exists(), isFalse);
    expect(await journal.list().toList(), isEmpty);
    blocked = false;
    flushed.clear();
    expect(
      await relocation.move(
        from,
        to,
        expected: revision,
        operationId: 'new-ancestry',
      ),
      isA<Moved>(),
    );
    expect(
      flushed,
      containsAllInOrder([
        p.join(support.path, 'relocation-writes'),
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

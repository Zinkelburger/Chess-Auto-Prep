@TestOn('linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/file_relocation.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/storage/training_rows.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'store_fixture.dart';

const _id = '1780000000000000-de1e7e';
const _originalRelative = 'Course/Main.pgn';
const _quarantineRelative = 'Course/.cap-pgn-history/$_id-Main.pgn';
const _books =
    '{"version":1,"future":{"keep":true},"books":[{"id":"book","name":"Book","repertoires":[],"chapters":[{"path":"Course/Main.pgn","section":"Main","annotation":7}]}]}';

void main() {
  late StoreFixture fixture;
  late DocumentRef from;
  late DocumentRef quarantine;
  late Revision revision;
  late Map<String, String> rows;
  final versions = [oneGame('1. d4'), oneGame('1. e4'), oneGame('1. c4')];

  File journal() =>
      File(p.join(fixture.support.path, 'relocation-writes', '$_id.json'));
  File books() => File(p.join(fixture.support.path, 'books.json'));
  File participant(String name) => File(p.join(fixture.documents.path, name));
  FileRelocations owner({FileRelocationStep? interrupt}) => FileRelocations(
    documents: fixture.documents,
    support: fixture.support,
    testHook: interrupt == null
        ? null
        : (step) async {
            if (step == interrupt) throw StateError('interrupted ${step.name}');
          },
  );

  setUp(() async {
    fixture = await StoreFixture.create();
    from = fixture.ref('repertoires/$_originalRelative');
    quarantine = fixture.ref('repertoires/$_quarantineRelative');
    revision = await fixture.put(from, versions.first);
    for (final text in versions.skip(1)) {
      revision =
          (await fixture.edit(from, text, revision) as Saved).receipt.committed;
    }
    expect(fixture.keptTexts(from), versions.take(2));
    rows = _trainingRows(from.path);
    for (final entry in rows.entries) {
      await participant(entry.key).writeAsString(entry.value);
    }
    await books().writeAsString(_books);
  });
  tearDown(() => fixture.dispose());

  Future<void> expectLocation({required bool deleted}) async {
    final current = deleted ? quarantine : from;
    final absent = deleted ? from : quarantine;
    expect(await File(current.path).readAsString(), versions.last);
    expect(await File(absent.path).exists(), isFalse);
    expect(fixture.keptTexts(current), versions);
    expect(fixture.backupFolder(absent).existsSync(), isFalse);
    for (final entry in rows.entries) {
      final expected = deleted
          ? entry.value.replaceAll(from.path, quarantine.path)
          : entry.value;
      expect(await participant(entry.key).readAsBytes(), utf8.encode(expected));
    }
    expect(
      await books().readAsString(),
      deleted
          ? _books.replaceFirst(_originalRelative, _quarantineRelative)
          : _books,
    );
  }

  Future<void> restore() async {
    final current = await fixture.revisionOf(quarantine);
    expect(
      await fixture.store.move(
        quarantine,
        from,
        expected: current,
        operationId: 'restore-1',
      ),
      isA<Moved>(),
    );
    await expectLocation(deleted: false);
  }

  for (final step in FileRelocationStep.values) {
    test(
      'delete interrupted at ${step.name} recovers, retries and restores all participants',
      () async {
        expect(
          await owner(
            interrupt: step,
          ).delete(from, expected: revision, operationId: _id),
          isA<IoFailure>(),
        );
        expect(
          (jsonDecode(await journal().readAsString()) as Map)['kind'],
          'delete',
        );
        await owner().recover();
        await expectLocation(deleted: step != FileRelocationStep.prepared);
        final settled = await journal().readAsBytes();
        await owner().recover();
        expect(await journal().readAsBytes(), settled);
        final result = await fixture.store.delete(
          from,
          expected: revision,
          operationId: _id,
        );
        expect(result, isA<Deleted>());
        expect((result as Deleted).recoveredTo, quarantine.path);
        await expectLocation(deleted: true);
        final completed = await journal().readAsBytes();
        expect(
          await fixture.store.delete(
            from,
            expected: revision,
            operationId: _id,
          ),
          isA<Deleted>(),
        );
        expect(await journal().readAsBytes(), completed);
        await restore();
      },
    );
  }

  test(
    'completed delete retry acknowledges original without deleting reused path',
    () async {
      expect(
        await fixture.store.delete(from, expected: revision, operationId: _id),
        isA<Deleted>(),
      );
      final completed = await journal().readAsBytes();
      await File(from.path).writeAsString(versions.last);
      final replacement = await fixture.revisionOf(from);
      expect(replacement.nativeIdentity, isNot(revision.nativeIdentity));
      final retry = await fixture.store.delete(
        from,
        expected: revision,
        operationId: _id,
      );
      expect((retry as Deleted).recoveredTo, quarantine.path);
      expect(await File(from.path).readAsString(), versions.last);
      expect(await File(quarantine.path).readAsString(), versions.last);
      expect(fixture.keptTexts(quarantine), versions);
      expect(fixture.backupFolder(from).existsSync(), isFalse);
      expect(await journal().readAsBytes(), completed);
      expect(
        await fixture.store.delete(
          from,
          expected: replacement,
          operationId: _id,
        ),
        isA<IoFailure>(),
      );
      expect(await File(from.path).readAsString(), versions.last);
    },
  );

  for (final initialKind in ['delete', 'move']) {
    test(
      '$initialKind operation id cannot be reused for the other kind',
      () async {
        final engine = owner();
        if (initialKind == 'delete') {
          expect(
            await engine.delete(from, expected: revision, operationId: _id),
            isA<Deleted>(),
          );
        } else {
          expect(
            await engine.move(
              from,
              quarantine,
              expected: revision,
              operationId: _id,
            ),
            isA<Moved>(),
          );
        }
        final completed = await journal().readAsBytes();
        final Object retry = initialKind == 'delete'
            ? await engine.move(
                from,
                quarantine,
                expected: revision,
                operationId: _id,
              )
            : await engine.delete(from, expected: revision, operationId: _id);
        expect(retry, isA<IoFailure>());
        expect(await journal().readAsBytes(), completed);
        expect(await File(from.path).exists(), isFalse);
        expect(await File(quarantine.path).readAsString(), versions.last);
      },
    );
  }

  test('accepted explicit delete id is visible in recovery listings', () async {
    final result =
        await fixture.store.delete(from, expected: revision, operationId: _id)
            as Deleted;
    final parsed = readRecoveryName(
      result.recoveredTo,
      folder: p.dirname(from.path),
    );
    expect(parsed, isNotNull);
    expect(parsed!.name, 'Main');
    expect(parsed.restoredAs(), from.path);
    expect(parsed.deletedAt.microsecondsSinceEpoch, 1780000000000000);
    final listed =
        await listDeleted(
              Directory(p.join(fixture.documents.path, 'repertoires')),
            )
            as DeletedChapters;
    expect(listed.chapters.map((chapter) => chapter.path), [quarantine.path]);
    await restore();
    final empty =
        await listDeleted(
              Directory(p.join(fixture.documents.path, 'repertoires')),
            )
            as DeletedChapters;
    expect(empty.chapters, isEmpty);
  });

  test('friendly delete id refuses before backup or other effects', () async {
    final backups = fixture.keptVersions(from);
    expect(
      await fixture.store.delete(
        from,
        expected: revision,
        operationId: 'delete-friendly',
      ),
      isA<IoFailure>(),
    );
    expect(await File(from.path).readAsString(), versions.last);
    expect(fixture.keptVersions(from), backups);
    expect(fixture.keptTexts(from), versions.take(2));
    expect(
      await Directory(
        p.join(p.dirname(from.path), '.cap-pgn-history'),
      ).exists(),
      isFalse,
    );
    expect(await Directory(p.dirname(journal().path)).exists(), isFalse);
    for (final entry in rows.entries) {
      expect(
        await participant(entry.key).readAsBytes(),
        utf8.encode(entry.value),
      );
    }
    expect(await books().readAsString(), _books);
  });

  test(
    'backup refusal leaves original document and all references intact',
    () async {
      final index = File(p.join(fixture.backupFolder(from).path, 'index.json'));
      await index.writeAsString('unrecognized index');
      expect(
        await fixture.store.delete(from, expected: revision, operationId: _id),
        isA<IoFailure>(),
      );
      expect(await File(from.path).readAsString(), versions.last);
      expect(await File(quarantine.path).exists(), isFalse);
      expect(await journal().exists(), isFalse);
      expect(await index.readAsString(), 'unrecognized index');
      for (final entry in rows.entries) {
        expect(
          await participant(entry.key).readAsBytes(),
          utf8.encode(entry.value),
        );
      }
      expect(await books().readAsString(), _books);
    },
  );
}

Map<String, String> _trainingRows(String path) => {
  reviewsFile:
      '\ufeffrepertoire_id,line_id,line_name,difficulty,interval_days,due_utc,last_rating,last_reviewed_utc,pass_count,fail_count,excluded\r\n'
      '$path,line,Mainline,2.5,1,2026-09-01T00:00:00Z,good,2026-08-31T00:00:00Z,2,0,false\r\n',
  streaksFile:
      'repertoire_id,line_id,move_index,correct_streak,learned\n$path,line,1,2,true\n',
  historyFile:
      'repertoire_id,line_id,timestamp_utc,rating,had_mistake,session_type\n$path,line,2026-08-31T00:00:00Z,good,false,trainer\n',
  attemptsFile:
      '${jsonEncode({
        'repertoireId': path,
        'future': [1, 'two'],
      })}\n'
      '{ "repertoireId": "/unrelated.pgn", "unknown": 17 }\n',
};

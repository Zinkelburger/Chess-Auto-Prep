@TestOn('linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/storage/backups.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/storage/file_relocation.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/training_rows.dart';
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
  FileRelocations owner({FileRelocationStep? interrupt}) {
    var interrupted = false;
    return FileRelocations(
      documents: fixture.documents,
      support: fixture.support,
      testHook: interrupt == null
          ? null
          : (step) async {
              if (step == interrupt && !interrupted) {
                interrupted = true;
                throw StateError('interrupted ${step.name}');
              }
            },
    );
  }

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
    final recorded = step != FileRelocationStep.prepared;

    test(
      'delete interrupted at ${step.name} finishes on the next start and restores',
      () async {
        expect(
          await owner(
            interrupt: step,
          ).delete(from, expected: revision, operationId: _id),
          isA<IoFailure>(),
        );
        await owner().recover();
        await expectLocation(deleted: recorded);
        expect(await journal().exists(), isFalse);
        await owner().recover();
        await expectLocation(deleted: recorded);
        if (recorded) await restore();
      },
    );

    test(
      'delete interrupted at ${step.name} is finished by its own retry',
      () async {
        final engine = owner(interrupt: step);
        expect(
          await engine.delete(from, expected: revision, operationId: _id),
          isA<IoFailure>(),
        );
        final result = await engine.delete(
          from,
          expected: revision,
          operationId: _id,
        );
        expect((result as Deleted).recoveredTo, quarantine.path);
        await expectLocation(deleted: true);
        expect(
          await engine.delete(from, expected: revision, operationId: _id),
          isA<Deleted>(),
        );
        await expectLocation(deleted: true);
        expect(await journal().exists(), isFalse);
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
      expect(await journal().exists(), isFalse);
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
        final Object retry = initialKind == 'delete'
            ? await engine.move(
                from,
                quarantine,
                expected: revision,
                operationId: _id,
              )
            : await engine.delete(from, expected: revision, operationId: _id);
        expect(retry, isA<IoFailure>());
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

  group('kept versions that cannot follow the delete at once', () {
    Directory owedMoves() =>
        Directory(p.join(fixture.support.path, 'backup-moves'));
    // Something in the way of the history's new id when the delete moves it,
    // as a folder held open on Windows is.
    File blocker() => File(fixture.backupFolder(quarantine).path);

    Future<void> deleteBlocked() async {
      final engine = FileRelocations(
        documents: fixture.documents,
        support: fixture.support,
        testHook: (step) async {
          if (step == FileRelocationStep.books) {
            await blocker().writeAsString('in the way');
          }
        },
      );
      expect(
        await engine.delete(from, expected: revision, operationId: _id),
        isA<Deleted>(),
      );
      expect(await journal().exists(), isFalse);
      expect(fixture.keptTexts(from), versions);
    }

    test('move on the next start, so the old path starts afresh', () async {
      await deleteBlocked();
      await blocker().delete();
      await owner().recover();

      await expectLocation(deleted: true);
      final index =
          jsonDecode(
                await File(
                  p.join(fixture.backupFolder(quarantine).path, 'index.json'),
                ).readAsString(),
              )
              as Map<String, Object?>;
      expect(index['path'], quarantine.path);
      final archive = BackupArchive(
        Directory(p.join(fixture.support.path, 'backups')),
      );
      expect(
        await archive.versions(p.basename(fixture.backupFolder(from).path)),
        isEmpty,
      );
      expect(owedMoves().listSync(), isEmpty);
    });

    test('stay with the chapter when it is restored first', () async {
      await deleteBlocked();
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
      await blocker().delete();
      await owner().recover();

      await expectLocation(deleted: false);
      expect(owedMoves().listSync(), isEmpty);
    });

    test('merge with what a renamed chapter kept meanwhile', () async {
      final renamed = fixture.ref('repertoires/Course/Renamed.pgn');
      final engine = FileRelocations(
        documents: fixture.documents,
        support: fixture.support,
        testHook: (step) async {
          if (step == FileRelocationStep.books) {
            await File(fixture.backupFolder(renamed).path).writeAsString('x');
          }
        },
      );
      expect(
        await engine.move(from, renamed, expected: revision, operationId: _id),
        isA<Moved>(),
      );
      expect(owedMoves().listSync(), hasLength(1));
      await File(fixture.backupFolder(renamed).path).delete();
      final saved = await fixture.edit(
        renamed,
        oneGame('1. Nf3'),
        await fixture.revisionOf(renamed),
      );
      expect(saved, isA<Saved>());
      await owner().recover();

      expect(fixture.keptTexts(renamed), versions);
      expect(fixture.backupFolder(from).existsSync(), isFalse);
      expect(
        Directory(
          p.join(
            fixture.documents.path,
            'repertoires',
            'Course',
            '.cap-pgn-history',
          ),
        ).existsSync(),
        isFalse,
      );
      expect(owedMoves().listSync(), isEmpty);
    });

    test(
      'a passing failure keeps the move and retries it',
      () async {
        final renamed = fixture.ref('repertoires/Course/Renamed.pgn');
        final backups = Directory(p.join(fixture.support.path, 'backups'));
        final engine = FileRelocations(
          documents: fixture.documents,
          support: fixture.support,
          testHook: (step) async {
            // No new entries can be made there, as while another program
            // holds it, until the permission comes back.
            if (step == FileRelocationStep.books) {
              await Process.run('chmod', ['555', backups.path]);
            }
          },
        );
        addTearDown(() => Process.run('chmod', ['755', backups.path]));
        expect(
          await engine.move(
            from,
            renamed,
            expected: revision,
            operationId: _id,
          ),
          isA<IoFailure>(),
        );
        await Process.run('chmod', ['755', backups.path]);
        expect(await journal().exists(), isTrue);
        expect(owedMoves().existsSync(), isFalse);
        expect(fixture.keptTexts(from), versions.take(2));

        await owner().recover();
        expect(await journal().exists(), isFalse);
        expect(fixture.keptTexts(renamed), versions.take(2));
        expect(fixture.backupFolder(from).existsSync(), isFalse);
        expect(fixture.quarantined(), isEmpty);
      },
      skip: Platform.environment['USER'] == 'root'
          ? 'needs permissions'
          : false,
    );

    test('a damaged note of one is set aside, never in the way', () async {
      await owedMoves().create();
      await File(p.join(owedMoves().path, 'damaged.json')).writeAsString('{}');
      await owner().recover();
      expect(owedMoves().listSync(), isEmpty);
      final quarantined = Directory(
        p.join(fixture.support.path, 'recovery-quarantine'),
      ).listSync(recursive: true).map((e) => p.basename(e.path));
      expect(quarantined, contains('backup-moves-damaged.json'));
      expect(fixture.keptTexts(from), versions.take(2));
    });
  });

  test(
    'an unreadable list of kept versions does not stop the delete',
    () async {
      final index = File(p.join(fixture.backupFolder(from).path, 'index.json'));
      await index.writeAsString('unrecognized index');
      final result = await fixture.store.delete(
        from,
        expected: revision,
        operationId: _id,
      );
      expect((result as Deleted).recoveredTo, quarantine.path);
      expect(await File(quarantine.path).readAsString(), versions.last);
      expect(await File(from.path).exists(), isFalse);
      // The damaged list is kept aside with the history, never deleted.
      final kept = fixture.backupFolder(quarantine).listSync();
      expect(
        kept.map((e) => p.basename(e.path)),
        contains(startsWith('index.json.corrupt-')),
      );
      expect(fixture.keptTexts(quarantine), versions);
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

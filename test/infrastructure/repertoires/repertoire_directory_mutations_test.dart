import 'dart:async';
import 'package:chess_auto_prep/features/games/services/my_repertoire_settings.dart';
import 'dart:convert';
import 'dart:io';
import 'package:csv/csv.dart';

import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_recovery_required.dart';
import 'package:chess_auto_prep/features/settings/models/repertoire_books.dart';
import 'package:chess_auto_prep/infrastructure/documents/native_pgn_document_store.dart';
import 'package:chess_auto_prep/infrastructure/repertoires/repertoire_directory_mutations.dart';
import 'package:chess_auto_prep/infrastructure/settings/shared_preferences_app_settings_repository.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:chess_auto_prep/utils/atomic_file.dart';
import 'package:document_file_io/document_file_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory profile;
  late Directory root;
  late Directory source;
  late String chapter;
  late SharedPreferencesAppSettingsRepository settings;

  IOStorageService storage({RepertoireMoveStep? failAt}) => IOStorageService(
    documentsRoot: profile,
    supportRoot: profile,
    repertoiresRoot: root,
    repertoireBooks: settings.repertoireBooks,
    repertoireMoveHook: failAt == null
        ? null
        : (step) async {
            if (step == failAt) {
              throw StateError('Injected interruption at $step');
            }
          },
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    profile = await Directory.systemTemp.createTemp('renewal-relocation-');
    root = await Directory(p.join(profile.path, 'repertoires')).create();
    source = await Directory(p.join(root.path, 'Old')).create();
    chapter = p.join(source.path, 'Main.pgn');
    await File(chapter).writeAsString('{annotation}\n1. e4 e5 *');
    settings = SharedPreferencesAppSettingsRepository();
    await settings.repertoireBooks.setPaths(BookSide.white, [
      source.path,
      '${source.path}-other',
    ]);
    await settings.repertoireBooks.setPaths(BookSide.black, [source.path]);
  });
  tearDown(() => profile.delete(recursive: true));

  Future<List<Map<String, dynamic>>> journals() async {
    final directory = Directory(p.join(profile.path, 'repertoire-mutations'));
    if (!await directory.exists()) return [];
    return [
      await for (final file in directory.list())
        if (file is File && p.extension(file.path) == '.json')
          jsonDecode(await file.readAsString()) as Map<String, dynamic>,
    ];
  }

  Future<void> seedTraining() async {
    await File(p.join(profile.path, 'repertoire_reviews.csv')).writeAsString(
      'repertoire_id,line_id,line_name,difficulty,interval_days,due_utc,last_rating,last_reviewed_utc,pass_count,fail_count,excluded\n'
      '$chapter,line,Opening,2.50,0007,2027-01-01T00:00:00.000Z,good,,4,2,false\n',
    );
    await File(
      p.join(profile.path, 'repertoire_review_history.csv'),
    ).writeAsString(
      'repertoire_id,line_id,timestamp_utc,rating,had_mistake,session_type\n'
      '$chapter,line,2026-09-16T00:00:00.000Z,good,false,drilling\n',
    );
    await File(
      p.join(profile.path, 'repertoire_move_progress.csv'),
    ).writeAsString(
      'repertoire_id,line_id,move_index,correct_streak,learned\n$chapter,line,2,5,true\n',
    );
    await File(
      p.join(profile.path, 'repertoire_move_attempts.jsonl'),
    ).writeAsString(
      '${jsonEncode({
        'repertoireId': chapter,
        'lineId': 'line',
        'correct': false,
        'futureField': {'untouched': 7},
      })}\n'
      '${jsonEncode({'repertoireId': '${source.path}-other/Main.pgn', 'lineId': 'elsewhere'})}\n',
    );
  }

  for (final write in [false, true]) {
    test(
      'training ${write ? 'update' : 'read'} recovers before library reload',
      () async {
        await seedTraining();
        await expectLater(
          storage(
            failAt: RepertoireMoveStep.moved,
          ).renameRepertoireDirectory(source.path, 'New'),
          throwsA(isA<RepertoireRecoveryRequired>()),
        );
        final restarted = storage();
        final next = p.join(root.path, 'New', 'Main.pgn');
        final read = write
            ? await restarted.updateFile('repertoire_reviews.csv', (raw) {
                expect(raw, contains(next));
                expect(raw, isNot(contains(chapter)));
                return raw!;
              })
            : await restarted.readRepertoireReviewsCsv();
        expect(read, contains(next));
        expect((await journals()).single['state'], 'completed');
      },
      skip: !Platform.isLinux,
    );
  }

  test('v2 recovery files never stop v1 reading, writing or listing', () async {
    await seedTraining();
    final study = File(await storage().studyFilePath('Example'));
    await study.writeAsString('1. e4 *');
    final notes = await Directory(
      p.join(profile.path, 'unfinished-moves'),
    ).create();
    final note = File(p.join(notes.path, 'unknown.json'));
    await note.writeAsString('{unknown');
    final compound = await Directory(
      p.join(profile.path, 'compound-writes'),
    ).create();
    final pending = File(p.join(compound.path, 'rename.json'));
    await pending.writeAsString('{"version":1,"state":"committing"}');
    final elsewhere = await Directory(p.join(profile.path, 'other')).create();
    await Link(
      p.join(profile.path, 'relocation-writes'),
    ).create(elsewhere.path);
    final io = storage();
    expect(await io.readFile(chapter), isNotNull);
    expect(await io.readRepertoireReviewsCsv(), contains(chapter));
    expect(await io.listChapters(source.path), isNotEmpty);
    expect(await io.listRepertoires(), isNotEmpty);
    expect(await io.listStudyFiles(), isNotEmpty);
    await io.listTacticsSets();
    await io.writeFile(study.path, '1. d4 *');
    expect(await study.readAsString(), '1. d4 *');
    // v1 leaves v2's records alone for v2 to finish.
    expect(await note.readAsString(), '{unknown');
    expect(await pending.exists(), isTrue);
    expect(await elsewhere.list().toList(), isEmpty);
  }, skip: !Platform.isLinux);

  test(
    'training read waits behind the complete native move without reentry',
    () async {
      await seedTraining();
      final moved = Completer<void>();
      final release = Completer<void>();
      final io = IOStorageService(
        documentsRoot: profile,
        supportRoot: profile,
        repertoiresRoot: root,
        repertoireBooks: settings.repertoireBooks,
        repertoireMoveHook: (step) async {
          if (step == RepertoireMoveStep.moved) {
            moved.complete();
            await release.future;
          }
        },
      );
      final renaming = io.renameRepertoireDirectory(source.path, 'New');
      await moved.future;
      var readDone = false;
      final reading = storage().readRepertoireReviewsCsv().then((text) {
        readDone = true;
        return text;
      });
      try {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(readDone, isFalse);
      } finally {
        release.complete();
      }
      await renaming.timeout(const Duration(seconds: 5));
      expect(
        await reading.timeout(const Duration(seconds: 5)),
        contains(p.join(root.path, 'New', 'Main.pgn')),
      );
    },
    skip: !Platform.isLinux,
  );

  test(
    'guarded file rename rewrites attempts without acquiring the domain twice',
    () async {
      await seedTraining();
      final next = p.join(source.path, 'Renamed.pgn');
      await storage()
          .renameFile(chapter, next)
          .timeout(const Duration(seconds: 5));
      final attempts = await storage().readFile(
        'repertoire_move_attempts.jsonl',
      );
      expect(attempts, contains(next));
      expect(await File(chapter).exists(), isFalse);
    },
    skip: !Platform.isLinux,
  );

  test(
    'delete and restore retain bytes, history and parked book selections',
    () async {
      await seedTraining();
      final bytes = await File(chapter).readAsBytes();
      final books = MyRepertoireSettings(repository: settings.repertoireBooks);
      addTearDown(books.dispose);
      await storage().deleteRepertoireDirectory(source.path);
      expect(await storage().listRepertoires(), isEmpty);
      final entry = (await storage().listRepertoireRecovery()).single;
      expect(entry.name, 'Old');
      expect(entry.available, isTrue);
      expect(entry.originalPath, source.path);
      expect(books.blackPaths, isEmpty);
      expect(books.whitePaths, ['${source.path}-other']);
      final deletedPath =
          settings.repertoireBooks.state.committed!.black.single;
      expect(deletedPath, contains('.chess_auto_prep_trash'));
      expect(await File(p.join(deletedPath, 'Main.pgn')).readAsBytes(), bytes);
      // Reusing the original name must not adopt the deleted repertoire's history.
      await source.create();
      await File(chapter).writeAsString('new unrelated content');
      await expectLater(
        storage().restoreRepertoire(entry.id),
        throwsA(isA<FileSystemException>()),
      );
      expect(await File(chapter).readAsString(), 'new unrelated content');
      expect(
        (await storage().listRepertoireRecovery()).single.available,
        isTrue,
      );
      await storage().restoreRepertoire(entry.id, name: 'Restored');
      final restored = p.join(root.path, 'Restored');
      expect(await File(p.join(restored, 'Main.pgn')).readAsBytes(), bytes);
      expect(books.blackPaths, [restored]);
      for (final name in [
        'repertoire_reviews.csv',
        'repertoire_review_history.csv',
        'repertoire_move_progress.csv',
        'repertoire_move_attempts.jsonl',
      ]) {
        expect(
          await File(p.join(profile.path, name)).readAsString(),
          contains(p.join(restored, 'Main.pgn')),
        );
      }
      expect(await storage().listRepertoireRecovery(), isEmpty);
      await expectLater(
        storage().restoreRepertoire(entry.id),
        throwsStateError,
      );
      expect(await File(chapter).readAsString(), 'new unrelated content');
    },
    skip: !Platform.isLinux,
  );

  for (final restore in [false, true]) {
    for (final step in RepertoireMoveStep.values) {
      test(
        '${restore ? 'restore' : 'delete'} interruption at ${step.name} is resolved on restart',
        () async {
          await seedTraining();
          String? entryId;
          if (restore) {
            await storage().deleteRepertoireDirectory(source.path);
            entryId = (await storage().listRepertoireRecovery()).single.id;
          }
          await expectLater(
            restore
                ? storage(failAt: step).restoreRepertoire(entryId!)
                : storage(failAt: step).deleteRepertoireDirectory(source.path),
            throwsA(isA<RepertoireRecoveryRequired>()),
          );
          final restarted = storage();
          final library = await restarted.listRepertoires();
          final recovery = await restarted.listRepertoireRecovery();
          final moved = step != RepertoireMoveStep.prepared;
          final live = restore ? moved : !moved;
          expect(library.length, live ? 1 : 0);
          expect(recovery.length, live ? 0 : 1);
          expect(await File(chapter).exists(), live);
          final currentPath =
              settings.repertoireBooks.state.committed!.black.single;
          expect(currentPath == source.path, live);
          expect(
            await File(p.join(currentPath, 'Main.pgn')).readAsString(),
            contains('annotation'),
          );
          expect(
            (await journals()).every((record) => record['state'] != 'pending'),
            isTrue,
          );
          final receipts = await journals();
          await restarted.listRepertoires();
          expect(await journals(), receipts);
        },
        skip: !Platform.isLinux,
      );
    }
  }

  test('nested folder deletion restores in its original parent', () async {
    final nested = await Directory(p.join(source.path, 'Nested')).create();
    await File(p.join(nested.path, 'Lesson.pgn')).writeAsString('nested bytes');
    await storage().deleteRepertoireDirectory(nested.path);
    final entry = (await storage().listRepertoireRecovery()).single;
    expect(entry.originalPath, nested.path);
    await storage().restoreRepertoire(entry.id, name: 'Recovered lesson');
    expect(
      await File(
        p.join(source.path, 'Recovered lesson', 'Lesson.pgn'),
      ).readAsString(),
      'nested bytes',
    );
    expect(await File(chapter).exists(), isTrue);
  }, skip: !Platform.isLinux);

  test(
    'a forged restore receipt cannot hide an available recovery entry',
    () async {
      await storage().deleteRepertoireDirectory(source.path);
      final entry = (await storage().listRepertoireRecovery()).single;
      final record = (await journals()).single;
      final id = '${DateTime.now().microsecondsSinceEpoch}-abcdef';
      await File(
        p.join(profile.path, 'repertoire-mutations', '$id.json'),
      ).writeAsString(
        jsonEncode({
          ...record,
          'id': id,
          'kind': 'restore',
          'recoveryId': entry.id,
          'from': record['to'],
          'to': source.path,
          'identity': 'unrelated',
        }),
      );
      await expectLater(
        storage().listRepertoireRecovery(),
        throwsFormatException,
      );
      expect(
        await File(p.join(record['to'] as String, 'Main.pgn')).readAsString(),
        contains('annotation'),
      );
      expect(await source.exists(), isFalse);
    },
    skip: !Platform.isLinux,
  );

  test(
    'replacement in recovery is visible but cannot authorize restore',
    () async {
      await storage().deleteRepertoireDirectory(source.path);
      final entry = (await storage().listRepertoireRecovery()).single;
      final trashPath = settings.repertoireBooks.state.committed!.black.single;
      await Directory(trashPath).rename('$trashPath-original');
      await Directory(trashPath).create();
      await File(p.join(trashPath, 'Other.pgn')).writeAsString('external');
      expect(
        (await storage().listRepertoireRecovery()).single.available,
        isFalse,
      );
      await expectLater(
        storage().restoreRepertoire(entry.id),
        throwsStateError,
      );
      expect(await source.exists(), isFalse);
      expect(
        await File(p.join('$trashPath-original', 'Main.pgn')).readAsString(),
        contains('annotation'),
      );
      expect(
        await File(p.join(trashPath, 'Other.pgn')).readAsString(),
        'external',
      );
    },
    skip: !Platform.isLinux,
  );

  test(
    'original name becoming a symlink does not prevent restore under another name',
    () async {
      await storage().deleteRepertoireDirectory(source.path);
      await Link(source.path).create(profile.path);
      final entry = (await storage().listRepertoireRecovery()).single;
      await expectLater(
        storage().restoreRepertoire(entry.id),
        throwsA(isA<Exception>()),
      );
      await storage().restoreRepertoire(entry.id, name: 'Recovered');
      expect(
        await File(p.join(root.path, 'Recovered', 'Main.pgn')).exists(),
        isTrue,
      );
      expect(await Link(source.path).target(), profile.path);
    },
    skip: !Platform.isLinux,
  );

  test(
    'linked recovery root and forged recovery ids never move live data',
    () async {
      final elsewhere = await Directory(
        p.join(profile.path, 'elsewhere'),
      ).create();
      await Link(
        p.join(profile.path, '.chess_auto_prep_trash'),
      ).create(elsewhere.path);
      await expectLater(
        storage().deleteRepertoireDirectory(source.path),
        throwsA(isA<Exception>()),
      );
      expect(await File(chapter).exists(), isTrue);
      expect(await elsewhere.list().toList(), isEmpty);
      await expectLater(
        storage().restoreRepertoire('../outside'),
        throwsStateError,
      );
    },
    skip: !Platform.isLinux,
  );

  test('competing restore operations move a receipt only once', () async {
    await storage().deleteRepertoireDirectory(source.path);
    final entry = (await storage().listRepertoireRecovery()).single;
    final results = await Future.wait([
      for (final name in ['First', 'Second'])
        storage()
            .restoreRepertoire(entry.id, name: name)
            .then<Object?>((_) => null, onError: (Object e) => e),
    ]);
    expect(results.where((r) => r == null), hasLength(1));
    expect(results.whereType<StateError>(), hasLength(1));
    expect(await storage().listRepertoires(), hasLength(1));
    expect(await storage().listRepertoireRecovery(), isEmpty);
  }, skip: !Platform.isLinux);

  test('external creation after restore intent is never overwritten', () async {
    await storage().deleteRepertoireDirectory(source.path);
    final entry = (await storage().listRepertoireRecovery()).single;
    final io = IOStorageService(
      documentsRoot: profile,
      supportRoot: profile,
      repertoiresRoot: root,
      repertoireBooks: settings.repertoireBooks,
      repertoireMoveHook: (step) async {
        if (step == RepertoireMoveStep.prepared) {
          await source.create();
          await File(chapter).writeAsString('competing creator');
        }
      },
    );
    await expectLater(
      io.restoreRepertoire(entry.id),
      throwsA(isA<FileSystemException>()),
    );
    expect(await File(chapter).readAsString(), 'competing creator');
    expect((await storage().listRepertoireRecovery()).single.available, isTrue);
    await storage().restoreRepertoire(entry.id, name: 'Safe');
    expect(
      await File(p.join(root.path, 'Safe', 'Main.pgn')).readAsString(),
      contains('annotation'),
    );
  }, skip: !Platform.isLinux);

  test(
    'native directory observation distinguishes rename, replacement, absence and links',
    () async {
      final first = await observeDirectory(source.path);
      expect(first.status, 0);
      final renamed = await source.rename(p.join(root.path, 'New'));
      expect((await observeDirectory(renamed.path)).identity, first.identity);
      expect((await observeDirectory(source.path)).status, 1);
      await source.create();
      expect(
        (await observeDirectory(source.path)).identity,
        isNot(first.identity),
      );
      final link = Link(p.join(root.path, 'Alias'));
      await link.create(renamed.path);
      expect((await observeDirectory(link.path)).status, isNot(0));
      expect(
        (await observeDirectory(p.join(renamed.path, 'Main.pgn'))).status,
        isNot(0),
      );
    },
    skip: !Platform.isLinux,
  );

  test(
    'rename keeps all training formats, unknown values, backups and both books',
    () async {
      await seedTraining();
      final original = await File(chapter).readAsBytes();
      final moved = await storage().renameRepertoireDirectory(
        source.path,
        'New',
      );
      final newChapter = p.join(moved, 'Main.pgn');
      expect(await File(newChapter).readAsBytes(), original);
      for (final name in [
        'repertoire_reviews.csv',
        'repertoire_review_history.csv',
        'repertoire_move_progress.csv',
        'repertoire_move_attempts.jsonl',
      ]) {
        final data = await File(p.join(profile.path, name)).readAsString();
        expect(data, contains(newChapter));
        final backup = File(
          p.join(
            profile.path,
            '.cap-reference-history',
            (await journals()).single['id'] as String,
            name,
          ),
        );
        expect(await backup.readAsString(), contains(chapter));
      }
      final schedule = await File(
        p.join(profile.path, 'repertoire_reviews.csv'),
      ).readAsString();
      expect(
        schedule,
        contains('2.50,0007,2027-01-01T00:00:00.000Z,good,,4,2,false'),
      );
      expect(settings.repertoireBooks.state.committed!.white, [
        moved,
        '${source.path}-other',
      ]);
      expect(settings.repertoireBooks.state.committed!.black, [moved]);
      expect((await journals()).single['state'], 'completed');
    },
    skip: !Platform.isLinux,
  );

  test(
    'quoted multiline fields and legacy comma paths survive reference migration',
    () async {
      final comma = await source.rename(p.join(root.path, 'Old, course'));
      final oldChapter = p.join(comma.path, 'Main.pgn');
      final file = File(p.join(profile.path, 'repertoire_reviews.csv'));
      final codec = Csv(autoDetect: false, lineDelimiter: '\n');
      await file.writeAsString(
        codec.encode([
          ['repertoire_id', 'line_id', 'line_name', 'future_field'],
          [oldChapter, 'line', 'Name, with\nnewline', '0003'],
        ]),
      );
      final moved = await storage().renameRepertoireDirectory(
        comma.path,
        'New',
      );
      final row = codec.decode(await file.readAsString())[1];
      expect(row, [
        p.join(moved, 'Main.pgn'),
        'line',
        'Name, with\nnewline',
        '0003',
      ]);
      final history = File(
        p.join(profile.path, 'repertoire_review_history.csv'),
      );
      await history.writeAsString(
        'repertoire_id,line_id,timestamp_utc,rating,had_mistake,session_type\n${p.join(moved, 'Main.pgn')},line,2026-01-01,good,false,drilling\n',
      );
      await storage().renameRepertoireDirectory(moved, 'Again, course');
      // Simulate the historic unquoted path format before the next move.
      final rawPath = p.join(root.path, 'Again, course', 'Main.pgn');
      await history.writeAsString(
        'repertoire_id,line_id,timestamp_utc,rating,had_mistake,session_type\n$rawPath,line,2026-01-01,good,false,drilling\n',
      );
      await storage().renameRepertoireDirectory(p.dirname(rawPath), 'Final');
      expect(codec.decode(await history.readAsString())[1], [
        p.join(root.path, 'Final', 'Main.pgn'),
        'line',
        '2026-01-01',
        'good',
        'false',
        'drilling',
      ]);
    },
    skip: !Platform.isLinux,
  );

  for (final step in RepertoireMoveStep.values) {
    test(
      'restart recovers interruption at ${step.name} without replaying the rename',
      () async {
        await seedTraining();
        await expectLater(
          storage(failAt: step).renameRepertoireDirectory(source.path, 'New'),
          throwsA(isA<RepertoireRecoveryRequired>()),
        );
        final restarted = storage();
        final listing = await restarted.listRepertoires();
        final didMove = step != RepertoireMoveStep.prepared;
        expect(listing.single.name, didMove ? 'New' : 'Old');
        expect(settings.repertoireBooks.state.committed!.black, [
          didMove ? p.join(root.path, 'New') : source.path,
        ]);
        expect(
          (await journals()).single['state'],
          didMove ? 'completed' : 'cancelled',
        );
        final before = await File(
          p.join(profile.path, 'repertoire_reviews.csv'),
        ).readAsString();
        await restarted.listRepertoires();
        expect(
          await File(
            p.join(profile.path, 'repertoire_reviews.csv'),
          ).readAsString(),
          before,
        );
      },
      skip: !Platform.isLinux,
    );
  }

  test(
    'destination collision produces no intent and never changes either folder',
    () async {
      final destination = await Directory(p.join(root.path, 'New')).create();
      await File(p.join(destination.path, 'Other.pgn')).writeAsString('newer');
      await expectLater(
        storage().renameRepertoireDirectory(source.path, 'New'),
        throwsA(isA<FileSystemException>()),
      );
      expect(await journals(), isEmpty);
      expect(await File(chapter).exists(), isTrue);
      expect(
        await File(p.join(destination.path, 'Other.pgn')).readAsString(),
        'newer',
      );
    },
    skip: !Platform.isLinux,
  );

  test(
    'native no-replace handles an external creator after intent validation',
    () async {
      final target = Directory(p.join(root.path, 'New'));
      final io = IOStorageService(
        documentsRoot: profile,
        supportRoot: profile,
        repertoiresRoot: root,
        repertoireBooks: settings.repertoireBooks,
        repertoireMoveHook: (step) async {
          if (step == RepertoireMoveStep.prepared) {
            await target.create();
            await File(
              p.join(target.path, 'Newer.pgn'),
            ).writeAsString('external');
          }
        },
      );
      await expectLater(
        io.renameRepertoireDirectory(source.path, 'New'),
        throwsA(isA<FileSystemException>()),
      );
      expect(await File(chapter).exists(), isTrue);
      expect(
        await File(p.join(target.path, 'Newer.pgn')).readAsString(),
        'external',
      );
      expect((await journals()).single['state'], 'cancelled');
      expect(settings.repertoireBooks.state.committed!.black, [source.path]);
    },
    skip: !Platform.isLinux,
  );

  test(
    'replacement at destination cannot authorize reference recovery',
    () async {
      await expectLater(
        storage(
          failAt: RepertoireMoveStep.moved,
        ).renameRepertoireDirectory(source.path, 'New'),
        throwsA(isA<RepertoireRecoveryRequired>()),
      );
      final destination = Directory(p.join(root.path, 'New'));
      await destination.rename(p.join(root.path, 'Preserved original'));
      await destination.create();
      await File(
        p.join(destination.path, 'Other.pgn'),
      ).writeAsString('unrelated');
      await expectLater(
        storage().listRepertoires(),
        throwsA(isA<RepertoireRecoveryRequired>()),
      );
      expect(settings.repertoireBooks.state.committed!.black, [source.path]);
      expect((await journals()).single['state'], 'pending');
      expect(
        await File(p.join(destination.path, 'Other.pgn')).readAsString(),
        'unrelated',
      );
    },
    skip: !Platform.isLinux,
  );

  test(
    'replacement during reference updates cannot be acknowledged as completed',
    () async {
      final target = Directory(p.join(root.path, 'New'));
      final io = IOStorageService(
        documentsRoot: profile,
        supportRoot: profile,
        repertoiresRoot: root,
        repertoireBooks: settings.repertoireBooks,
        repertoireMoveHook: (step) async {
          if (step == RepertoireMoveStep.referencesUpdated) {
            await target.rename(p.join(root.path, 'Preserved'));
            await target.create();
          }
        },
      );
      await expectLater(
        io.renameRepertoireDirectory(source.path, 'New'),
        throwsA(isA<RepertoireRecoveryRequired>()),
      );
      expect((await journals()).single['state'], 'pending');
      expect(
        await File(p.join(root.path, 'Preserved', 'Main.pgn')).readAsString(),
        contains('annotation'),
      );
    },
    skip: !Platform.isLinux,
  );

  test('invalid journal ids cannot select a reference backup path', () async {
    final observation = await observeDirectory(source.path);
    final target = p.join(root.path, 'New');
    await source.rename(target);
    final directory = await Directory(
      p.join(profile.path, 'repertoire-mutations'),
    ).create();
    await File(p.join(directory.path, '...json')).writeAsString(
      jsonEncode({
        'version': 1,
        'id': '..',
        'from': source.path,
        'to': target,
        'identity': observation.identity,
        'state': 'pending',
      }),
    );
    await expectLater(storage().listRepertoires(), throwsFormatException);
    expect(settings.repertoireBooks.state.committed!.black, [source.path]);
    expect(
      await File(p.join(target, 'Main.pgn')).readAsString(),
      contains('annotation'),
    );
  }, skip: !Platform.isLinux);

  test('reused source name is ambiguous and retains the journal', () async {
    await expectLater(
      storage(
        failAt: RepertoireMoveStep.moved,
      ).renameRepertoireDirectory(source.path, 'New'),
      throwsA(isA<RepertoireRecoveryRequired>()),
    );
    await source.create();
    await expectLater(
      storage().listRepertoires(),
      throwsA(isA<RepertoireRecoveryRequired>()),
    );
    expect((await journals()).single['state'], 'pending');
  }, skip: !Platform.isLinux);

  test(
    'partial reference failure retries already migrated files idempotently',
    () async {
      await seedTraining();
      final progress = File(
        p.join(profile.path, 'repertoire_move_progress.csv'),
      );
      final original = await progress.readAsString();
      await progress.writeAsString('unrecognized header\nkeep this data');
      await expectLater(
        storage().renameRepertoireDirectory(source.path, 'New'),
        throwsA(isA<RepertoireRecoveryRequired>()),
      );
      expect(settings.repertoireBooks.state.committed!.black, [source.path]);
      expect(await progress.readAsString(), contains('keep this data'));
      // Explicit fixture repair permits recovery; it never discards bad data itself.
      await progress.writeAsString(original);
      await storage().listRepertoires();
      expect(settings.repertoireBooks.state.committed!.black, [
        p.join(root.path, 'New'),
      ]);
      expect((await journals()).single['state'], 'completed');
    },
    skip: !Platform.isLinux,
  );

  test(
    'native document commit holds the same domain lock as directory move',
    () async {
      final io = storage();
      final staged = Completer<void>();
      final release = Completer<void>();
      final documents = NativePgnDocumentStore(
        guardOperation: io.guardDocumentOperation,
        writer: AtomicFileWriter(
          testHook: (step) async {
            if (step == AtomicWriteStep.tempFlushed) {
              staged.complete();
              await release.future;
            }
          },
        ),
      );
      final baseline = (await documents.open(chapter) as PgnOpened).snapshot;
      final save = documents.save(baseline, '1. d4 d5 *');
      await staged.future;
      var moved = false;
      final rename = io.renameRepertoireDirectory(source.path, 'New').then((
        value,
      ) {
        moved = true;
        return value;
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(moved, isFalse);
      release.complete();
      expect(await save, isA<PgnSaved>());
      final destination = await rename;
      expect(
        await File(p.join(destination, 'Main.pgn')).readAsString(),
        '1. d4 d5 *',
      );
      expect(await documents.save(baseline, 'stale'), isA<PgnConflict>());
      expect(await source.exists(), isFalse);
    },
    skip: !Platform.isLinux,
  );

  test(
    'storage with only a documents override keeps support and repertoires in its fixture',
    () async {
      final io = IOStorageService(documentsRoot: profile);
      expect(
        await io.repertoireDirectoryPath('Example'),
        p.join(profile.path, 'repertoires', 'Example'),
      );
      await io.renameRepertoireDirectory(source.path, 'New');
      expect((await journals()).single['state'], 'completed');
    },
    skip: !Platform.isLinux,
  );
}

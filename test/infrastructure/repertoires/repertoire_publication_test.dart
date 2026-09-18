import 'package:chess_auto_prep/infrastructure/documents/native_pgn_document_store.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/features/repertoires/models/repertoire_creation.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_recovery_required.dart';
import 'package:chess_auto_prep/infrastructure/repertoires/native_repertoire_publication_store.dart';
import 'package:chess_auto_prep/infrastructure/repertoires/repertoire_directory_mutations.dart';
import 'package:chess_auto_prep/infrastructure/repertoires/repertoire_import_planner.dart';
import 'package:chess_auto_prep/services/repertoire_creation.dart';
import 'package:chess_auto_prep/services/repertoire_service.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:chess_auto_prep/services/storage/file_mutation_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

String game(String chapter, String name, String moves) =>
    '[Event "Course"]\n[White "$chapter"]\n[Black "$name"]\n[Result "*"]\n'
    '[EventDate "2026.??.??"]\n[FutureTag "preserved"]\n\n$moves *\n\n';
final course =
    '${game('French', 'Advance', '1. e4 e6 2. d4 d5 3. e5 {annotation} c5')}'
    '${game('French', 'Exchange', '1. e4 e6 2. d4 d5 3. exd5 exd5')}'
    '${game('Caro-Kann', 'Classical', '1. e4 c6 2. d4 d5 3. Nc3 dxe4')}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory profile;
  late Directory root;
  IOStorageService storage({
    Future<void> Function(RepertoirePublicationStep)? hook,
  }) => IOStorageService(
    documentsRoot: profile,
    supportRoot: profile,
    repertoiresRoot: root,
    repertoirePublicationHook: hook,
  );
  Future<RepertoireCreationResult> create(
    IOStorageService io, {
    String name = 'Course',
  }) => createRepertoire(
    documents: NativePgnDocumentStore(
      guardOperation: io.guardDocumentOperation,
    ),
    storage: io,
    name: name,
    color: 'Black',
    pgnContent: course,
  );
  Directory staging() =>
      Directory(p.join(root.path, RepertoireDirectoryMutations.stagingName));
  Future<List<File>> manifests() async => [
    await for (final file in staging().list(
      recursive: true,
      followLinks: false,
    ))
      if (file is File && p.basename(file.path) == 'publication.json') file,
  ];
  Future<Directory> payload() async =>
      Directory(p.join((await manifests()).single.parent.path, 'payload'));
  Future<List<Map<String, dynamic>>> receipts() async => [
    for (final file in await manifests())
      jsonDecode(await file.readAsString()) as Map<String, dynamic>,
  ];

  setUp(() async {
    profile = await Directory.systemTemp.createTemp('repertoire-publication-');
    root = await Directory(p.join(profile.path, 'repertoires')).create();
  });
  tearDown(() => profile.delete(recursive: true));

  test(
    'planning preserves ordered course names, IDs, annotations and unknown headers',
    () {
      final plan = planRepertoireImport(
        CreateRepertoire(name: 'Course', color: 'Black', pgnContent: course),
        DateTime(2026),
      );
      expect(plan.chapters.keys, ['French.pgn', 'Caro-Kann.pgn']);
      expect(plan.gameCount, 3);
      expect(plan.sourceContent, course);
      final french = plan.chapters['French.pgn']!;
      expect(french, contains('{annotation}'));
      expect(french, contains('[FutureTag "preserved"]'));
      expect(french, contains('[EventDate "2026.??.??"]'));
      expect(french, contains('[LineID "'));
      final lines = RepertoireService().parseRepertoirePgn(french);
      expect(lines.map((l) => l.name), ['Advance', 'Exchange']);
      expect(lines.map((l) => l.id).toSet(), hasLength(2));
      expect(plan.chapters['Caro-Kann.pgn'], contains('[Event "Classical"]'));
    },
  );

  test(
    'planning reserves safe unique names without dropping colliding titles',
    () {
      final input =
          '${game('CON', 'A', '1. e4 e5')}'
          '${game('CON', 'A2', '1. e4 c5')}'
          '${game('A:B', 'B', '1. d4 d5')}'
          '${game('A?B', 'C', '1. c4 e5')}';
      final plan = planRepertoireImport(
        CreateRepertoire(name: 'Course', color: 'White', pgnContent: input),
        DateTime(2026),
      );
      expect(plan.chapters.keys, ['Chapter CON.pgn', 'A B.pgn', 'A B (2).pgn']);
    },
  );

  test('model games stay in Main with their model identity pinned', () {
    final input =
        '$course[Event "Illustration"]\n[White "Player One"]\n'
        '[Black "Player Two"]\n[Result "1-0"]\n\n1. d4 d5 2. c4 e6 1-0\n';
    final plan = planRepertoireImport(
      CreateRepertoire(name: 'Course', color: 'Black', pgnContent: input),
      DateTime(2026),
    );
    expect(plan.chapters.keys, ['French.pgn', 'Caro-Kann.pgn', 'Main.pgn']);
    final model = RepertoireService()
        .parseRepertoirePgn(plan.chapters['Main.pgn']!)
        .single;
    expect(model.isModelGame, isTrue);
    // In a course, the original display title comes from the Black header.
    expect(model.name, 'Player Two');
    expect(plan.chapters['Main.pgn'], contains('[White "Player One"]'));
    expect(plan.chapters['Main.pgn'], contains('[Result "1-0"]'));
  });

  test(
    'variation expansion keeps both branches in a single planned chapter',
    () {
      const input = '[Event "Lines"]\n\n1. e4 e5 (1... c5 {Sicilian}) *';
      final plan = planRepertoireImport(
        const CreateRepertoire(
          name: 'Lines',
          color: 'White',
          pgnContent: input,
          splitChapters: false,
        ),
        DateTime(2026),
      );
      expect(plan.chapters.keys, ['Main.pgn']);
      expect(plan.gameCount, 2);
      final lines = RepertoireService().parseRepertoirePgn(
        plan.chapters.values.single,
      );
      expect(lines.map((line) => line.moves), [
        ['e4', 'e5'],
        ['e4', 'c5'],
      ]);
      expect(plan.chapters.values.single, contains('Sicilian'));
      expect(plan.sourceContent, input);
    },
  );

  test(
    'failure after the last private chapter still publishes nothing',
    () async {
      var written = 0;
      await expectLater(
        create(
          storage(
            hook: (step) async {
              if (step == RepertoirePublicationStep.chapterWritten &&
                  ++written == 2) {
                throw StateError('Last private chapter written');
              }
            },
          ),
        ),
        throwsA(isA<RepertoirePreparationFailed>()),
      );
      expect(written, 2);
      expect(await storage().listRepertoires(), isEmpty);
      expect(await manifests(), isEmpty);
      final pgns = await staging()
          .list(recursive: true)
          .where((e) => e is File && p.extension(e.path) == '.pgn')
          .toList();
      expect(pgns, hasLength(3)); // source plus both private chapters
    },
    skip: !Platform.isLinux,
  );

  test(
    'all chapters appear together and source input is retained outside the library',
    () async {
      final result = await create(
        storage(
          hook: (step) async {
            if (step == RepertoirePublicationStep.chapterWritten ||
                step == RepertoirePublicationStep.staged) {
              expect(await storage().listRepertoires(), isEmpty);
              expect(
                await Directory(p.join(root.path, 'Course')).exists(),
                isFalse,
              );
            }
          },
        ),
      );
      expect(result.chapterPaths.map(p.basename), [
        'French.pgn',
        'Caro-Kann.pgn',
      ]);
      expect((await storage().listRepertoires()).single.name, 'Course');
      expect(await storage().listChapters(result.directoryPath), hasLength(2));
      final receipt = (await receipts()).single;
      expect(receipt['state'], 'completed');
      expect(
        await File(
          p.join((await manifests()).single.parent.path, 'source.pgn'),
        ).readAsString(),
        course,
      );
      expect(await (await payload()).exists(), isFalse);
    },
    skip: !Platform.isLinux,
  );

  for (final step in RepertoirePublicationStep.values) {
    test(
      'interruption at ${step.name} never exposes an incomplete repertoire',
      () async {
        await expectLater(
          create(
            storage(
              hook: (current) async {
                if (current == step) throw StateError('Injected $step');
              },
            ),
          ),
          throwsA(
            anyOf(
              isA<RepertoirePreparationFailed>(),
              isA<RepertoireRecoveryRequired>(),
            ),
          ),
        );
        final live = await storage().listRepertoires();
        final installed =
            step == RepertoirePublicationStep.installed ||
            step == RepertoirePublicationStep.completed;
        expect(live.length, installed ? 1 : 0);
        if (installed) {
          expect(
            await storage().listChapters(live.single.filePath),
            hasLength(2),
          );
          expect((await receipts()).single['state'], 'completed');
        } else {
          expect(
            await Directory(p.join(root.path, 'Course')).exists(),
            isFalse,
          );
        }
        if (step == RepertoirePublicationStep.prepared) {
          expect((await receipts()).single['state'], 'cancelled');
        }
        final before = await receipts();
        await storage().listRepertoires();
        expect(await receipts(), before);
      },
      skip: !Platform.isLinux,
    );
  }

  test(
    'an existing empty destination is never merged into or replaced',
    () async {
      final existing = await Directory(p.join(root.path, 'Course')).create();
      await expectLater(
        create(storage()),
        throwsA(isA<RepertoireExistsException>()),
      );
      expect(await existing.list().toList(), isEmpty);
      expect((await receipts()).single['state'], 'staged');
    },
    skip: !Platform.isLinux,
  );

  test('concurrent case-folded names publish one complete winner', () async {
    final results = await Future.wait([
      create(
        storage(),
        name: 'Course',
      ).then<Object>((r) => r, onError: (Object e) => e),
      create(
        storage(),
        name: 'course',
      ).then<Object>((r) => r, onError: (Object e) => e),
    ]);
    expect(results.whereType<RepertoireCreationResult>(), hasLength(1));
    expect(results.whereType<RepertoireExistsException>(), hasLength(1));
    final live = (await storage().listRepertoires()).single;
    expect(await storage().listChapters(live.filePath), hasLength(2));
  }, skip: !Platform.isLinux);

  test(
    'external creation after commit intent wins without being overwritten',
    () async {
      final target = Directory(p.join(root.path, 'Course'));
      await expectLater(
        create(
          storage(
            hook: (step) async {
              if (step == RepertoirePublicationStep.prepared) {
                await target.create();
                await File(
                  p.join(target.path, 'External.pgn'),
                ).writeAsString('external');
              }
            },
          ),
        ),
        throwsA(isA<RepertoireExistsException>()),
      );
      expect(
        await File(p.join(target.path, 'External.pgn')).readAsString(),
        'external',
      );
      expect((await receipts()).single['state'], 'cancelled');
      expect(await (await payload()).exists(), isTrue);
    },
    skip: !Platform.isLinux,
  );

  test('changed staged content cannot be published', () async {
    await expectLater(
      create(
        storage(
          hook: (step) async {
            if (step == RepertoirePublicationStep.staged) {
              await File(
                p.join((await payload()).path, 'French.pgn'),
              ).writeAsString('tampered');
            }
          },
        ),
      ),
      throwsStateError,
    );
    expect(await storage().listRepertoires(), isEmpty);
    expect(
      await File(p.join((await payload()).path, 'French.pgn')).readAsString(),
      'tampered',
    );
  }, skip: !Platform.isLinux);

  test(
    'changed installed chapters retain pending receipt and block further managed writes',
    () async {
      await expectLater(
        create(
          storage(
            hook: (step) async {
              if (step == RepertoirePublicationStep.installed) {
                await File(
                  p.join(root.path, 'Course', 'French.pgn'),
                ).writeAsString('external edit');
              }
            },
          ),
        ),
        throwsA(isA<RepertoireRecoveryRequired>()),
      );
      await expectLater(
        storage().listRepertoires(),
        throwsA(isA<RepertoireRecoveryRequired>()),
      );
      await expectLater(
        storage().writeFile(p.join(root.path, 'Other', 'Main.pgn'), 'new'),
        throwsA(isA<RepertoireRecoveryRequired>()),
      );
      expect((await receipts()).single['state'], 'pending');
      expect(
        await File(p.join(root.path, 'Course', 'French.pgn')).readAsString(),
        'external edit',
      );
      expect(
        await File(
          p.join((await manifests()).single.parent.path, 'source.pgn'),
        ).readAsString(),
        course,
      );
    },
    skip: !Platform.isLinux,
  );

  test(
    'directory replacement cannot acknowledge an interrupted publication',
    () async {
      await expectLater(
        create(
          storage(
            hook: (step) async {
              if (step == RepertoirePublicationStep.installed) {
                throw StateError('interrupted');
              }
            },
          ),
        ),
        throwsA(isA<RepertoireRecoveryRequired>()),
      );
      final target = Directory(p.join(root.path, 'Course'));
      await target.rename(p.join(root.path, 'Preserved original'));
      await target.create();
      await expectLater(
        storage().listRepertoires(),
        throwsA(isA<RepertoireRecoveryRequired>()),
      );
      expect(await target.list().toList(), isEmpty);
      expect(
        await File(
          p.join(root.path, 'Preserved original', 'French.pgn'),
        ).exists(),
        isTrue,
      );
    },
    skip: !Platform.isLinux,
  );

  test('staging cannot be renamed or deleted as a repertoire', () async {
    await create(storage());
    await expectLater(
      storage().renameRepertoireDirectory(staging().path, 'Moved'),
      throwsA(isA<UnsafeFileMutation>()),
    );
    await expectLater(
      storage().deleteRepertoireDirectory(staging().path),
      throwsA(isA<UnsafeFileMutation>()),
    );
    expect(await staging().exists(), isTrue);
  }, skip: !Platform.isLinux);

  test('symlinked private staging never receives import data', () async {
    final outside = await Directory(p.join(profile.path, 'outside')).create();
    await Link(staging().path).create(outside.path);
    await expectLater(
      create(storage()),
      throwsA(isA<RepertoirePreparationFailed>()),
    );
    expect(await outside.list().toList(), isEmpty);
  }, skip: !Platform.isLinux);

  test('another listing waits for publication acknowledgement', () async {
    final installed = Completer<void>();
    final release = Completer<void>();
    final publishing = create(
      storage(
        hook: (step) async {
          if (step == RepertoirePublicationStep.installed) {
            installed.complete();
            await release.future;
          }
        },
      ),
    );
    await installed.future;
    var listed = false;
    final listing = storage().listRepertoires().then((r) {
      listed = true;
      return r;
    });
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(listed, isFalse);
    release.complete();
    await publishing;
    expect((await listing).single.name, 'Course');
  }, skip: !Platform.isLinux);
  for (final corruption in ['destination', 'chapter', 'digest', 'symlink']) {
    test(
      'invalid $corruption receipt cannot publish or mutate outside data',
      () async {
        await expectLater(
          create(
            storage(
              hook: (step) async {
                if (step == RepertoirePublicationStep.prepared) {
                  throw StateError('interrupted');
                }
              },
            ),
          ),
          throwsA(isA<RepertoireRecoveryRequired>()),
        );
        final manifest = (await manifests()).single;
        final value =
            jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;
        switch (corruption) {
          case 'destination':
            value['name'] = '../outside';
          case 'chapter':
            value['files'] = {
              '../outside.pgn': (value['files'] as Map).values.first,
            };
          case 'digest':
            (value['files'] as Map).values.first['digest'] = 'not a digest';
          case 'symlink':
            await manifest.rename('${manifest.path}.retained');
            await Link(manifest.path).create('${manifest.path}.retained');
        }
        if (corruption != 'symlink') {
          await manifest.writeAsString(jsonEncode(value));
        }
        await expectLater(
          storage().listRepertoires(),
          throwsA(anyOf(isA<ArgumentError>(), isA<FormatException>())),
        );
        expect(await Directory(p.join(root.path, 'Course')).exists(), isFalse);
        expect(
          await File(p.join(profile.path, 'outside.pgn')).exists(),
          isFalse,
        );
      },
      skip: !Platform.isLinux,
    );
  }
}

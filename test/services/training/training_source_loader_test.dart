import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:chess_auto_prep/infrastructure/documents/native_pgn_document_store.dart';
import '../../support/generation_artifacts_fixture.dart';
import 'package:chess_auto_prep/features/training/repositories/training_source_repository.dart';
import 'package:chess_auto_prep/features/training/repositories/training_answers.dart';
import 'dart:io';

import 'package:chess_auto_prep/features/repertoires/models/repertoire_metadata.dart';
import 'package:chess_auto_prep/models/repertoire_move_progress.dart';
import 'package:chess_auto_prep/services/asked_questions_store.dart';
import 'package:chess_auto_prep/infrastructure/training/training_source_loader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'training_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late FakeRepertoireService repService;
  late FakeReviewService reviewService;
  late AskedQuestionsStore askedQuestions;
  late TrainingSourceLoader loader;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('training_loader_test');
    StorageFactory.instanceForTest = null;
    PathProviderPlatform.instance = FakePathProvider(tempDir.path);
    repService = FakeRepertoireService();
    reviewService = FakeReviewService();
    askedQuestions = AskedQuestionsStore();
    loader = TrainingSourceLoader(
      documents: NativePgnDocumentStore(),
      artifacts: generationArtifactsFixture().repository,
      repertoireService: repService,
      reviewService: reviewService,
      askedQuestions: askedQuestions,
    );
  });

  tearDown(() async {
    StorageFactory.instanceForTest = null;
    await tempDir.delete(recursive: true);
  });

  RepertoireMetadata file(String name) {
    final path = p.join(tempDir.path, '$name.pgn');
    if (!File(path).existsSync()) File(path).writeAsStringSync('1. e4 *');
    return RepertoireMetadata(
      filePath: path,
      name: name,
      lastModified: DateTime.now(),
    );
  }

  test('a single file: lines, synced entries, keyed move progress', () async {
    final source = file('rep');
    repService.lines = [
      fakeLine('a', ['e4', 'e5']),
      fakeLine('b', ['d4', 'd5']),
    ];
    reviewService.entries = [
      fakeEntry(source.filePath, 'a'),
      fakeEntry('/elsewhere.pgn', 'z'),
    ];
    reviewService.progress = [
      RepertoireMoveProgress(
        repertoireId: source.filePath,
        lineId: 'b',
        moveIndex: 0,
        correctStreak: 2,
        learned: false,
      ),
    ];

    final loaded = await loader.load(
      source,
      isStudy: false,
      colorOverrideIsWhite: null,
      isStale: () => false,
    );

    expect(loaded, isNotNull);
    expect(loaded!.lines.map((l) => l.id), ['a', 'b']);
    expect(loaded.reviewByLine.keys, unorderedEquals(['a', 'b']));
    expect(loaded.reviewByLine['a']!.lastRating, 'good');
    expect(loaded.reviewByLine['b']!.isNew, isTrue, reason: 'synced fresh');
    expect(loaded.moveProgress.keys, ['b:0']);
    expect(loaded.otherRepertoires.map((e) => e.lineId), ['z']);
    expect(loaded.isFolder, isFalse);
    expect(reviewService.saveAllCalls, 1);
    expect(repService.parseCalls.single.trainingColor, isNull);
  });

  test(
    'reloading unchanged material does not rewrite the review store',
    () async {
      final source = file('rep');
      repService.lines = [
        fakeLine('a', ['e4', 'e5']),
      ];
      Future<LoadedTrainingSource?> reload() => loader.load(
        source,
        isStudy: false,
        colorOverrideIsWhite: null,
        isStale: () => false,
      );

      await reload();
      expect(reviewService.saveAllCalls, 1, reason: 'first open syncs fresh');
      final again = await reload();
      expect(reviewService.saveAllCalls, 1, reason: 'same rows, no write');
      expect(again!.reviewByLine.keys, ['a']);

      repService.lines = [
        fakeLine('a', ['e4', 'e5']),
        fakeLine('b', ['d4']),
      ];
      await reload();
      expect(reviewService.saveAllCalls, 2, reason: 'a new line changes rows');
    },
  );

  test('reports what it is doing, one chapter at a time', () async {
    final folder = Directory(p.join(tempDir.path, 'Course'))..createSync();
    File(p.join(folder.path, 'One.pgn')).writeAsStringSync('1. e4 e5 *');
    File(p.join(folder.path, 'Two.pgn')).writeAsStringSync('1. d4 d5 *');
    repService.lines = [
      fakeLine('shared', ['e4', 'e5']),
    ];
    final statuses = <String>[];

    await loader.load(
      RepertoireMetadata(
        filePath: folder.path,
        name: 'Course',
        lastModified: DateTime.now(),
      ),
      isStudy: false,
      colorOverrideIsWhite: null,
      isStale: () => false,
      onStatus: statuses.add,
    );

    expect(statuses, [
      'Preparing lines in One…',
      'Restoring review progress…',
      'Preparing lines in Two…',
      'Restoring review progress…',
    ]);
  });

  test('playability is empty without a generated tree', () async {
    final source = file('rep');
    final scores = await loader.playabilityFromTree(source.filePath, [
      fakeLine('a', ['e4', 'e5']),
    ]);
    expect(scores, isEmpty);
  });

  test('a superseded playability read stops before decoding', () async {
    final source = file('rep');
    File(
      '${p.withoutExtension(source.filePath)}_tree.json',
    ).writeAsStringSync('not even json');
    final scores = await loader.playabilityFromTree(source.filePath, [
      fakeLine('a', ['e4', 'e5']),
    ], isStale: () => true);
    expect(scores, isEmpty);
  });

  test('a hand-set colour is passed to the parser', () async {
    repService.lines = [
      fakeLine('a', ['e4']),
    ];
    await loader.load(
      file('rep'),
      isStudy: false,
      colorOverrideIsWhite: false,
      isStale: () => false,
    );
    expect(repService.parseCalls.single.trainingColor, 'black');
  });

  test('a source with nothing to train yields empty lines', () async {
    repService.lines = [];
    final loaded = await loader.load(
      file('rep'),
      isStudy: true,
      colorOverrideIsWhite: null,
      isStale: () => false,
    );
    expect(loaded, isNotNull);
    expect(loaded!.lines, isEmpty);
  });

  test('a superseded load stops before writing anything', () async {
    repService.lines = [
      fakeLine('a', ['e4']),
    ];
    final loaded = await loader.load(
      file('rep'),
      isStudy: false,
      colorOverrideIsWhite: null,
      // Stale as soon as the first await (the parse) has run.
      isStale: () => repService.parseCalls.isNotEmpty,
    );
    expect(loaded, isNull);
    expect(reviewService.saveAllCalls, 0);
  });

  test('a folder: every chapter under it, lines scoped per chapter, '
      'each chapter with its own remembered colour', () async {
    final folder = Directory(p.join(tempDir.path, 'Course'))..createSync();
    final nested = Directory(p.join(folder.path, 'Part 2'))..createSync();
    final one = File(p.join(folder.path, 'One.pgn'))
      ..writeAsStringSync('1. e4 e5 *');
    final two = File(p.join(nested.path, 'Two.pgn'))
      ..writeAsStringSync('1. d4 d5 *');
    await askedQuestions.record(
      AskedQuestion.trainingColor,
      subject: two.path,
      answer: false,
    );
    repService.lines = [
      fakeLine('shared', ['e4', 'e5']),
    ];

    final loaded = await loader.load(
      RepertoireMetadata(
        filePath: folder.path,
        name: 'Course',
        lastModified: DateTime.now(),
      ),
      isStudy: false,
      colorOverrideIsWhite: null,
      isStale: () => false,
    );

    expect(loaded, isNotNull);
    expect(loaded!.lines, hasLength(2));
    expect(loaded.lines.map((l) => l.id).toSet(), hasLength(2));
    expect(loaded.lines.map((l) => l.persistedId), ['shared', 'shared']);
    expect(loaded.lines.map((l) => l.sourcePath), [one.path, two.path]);
    expect(
      loaded.reviewByLine[loaded.lines.last.id]!.repertoireId,
      two.path,
      reason: 'entries follow the chapter they were parsed from',
    );
    expect(
      {for (final c in repService.parseCalls) c.filePath: c.trainingColor},
      {one.path: null, two.path: 'black'},
    );
  });
}

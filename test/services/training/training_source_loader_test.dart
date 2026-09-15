import 'dart:io';

import 'package:chess_auto_prep/models/repertoire_metadata.dart';
import 'package:chess_auto_prep/models/repertoire_move_progress.dart';
import 'package:chess_auto_prep/services/asked_questions_store.dart';
import 'package:chess_auto_prep/services/training/training_source_loader.dart';
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
    PathProviderPlatform.instance = FakePathProvider(tempDir.path);
    repService = FakeRepertoireService();
    reviewService = FakeReviewService();
    askedQuestions = AskedQuestionsStore();
    loader = TrainingSourceLoader(
      repertoireService: repService,
      reviewService: reviewService,
      askedQuestions: askedQuestions,
    );
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  RepertoireMetadata file(String name) => RepertoireMetadata(
    filePath: p.join(tempDir.path, '$name.pgn'),
    name: name,
    lastModified: DateTime.now(),
  );

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
    expect(loaded.playabilityByLine, isEmpty, reason: 'no tree.json');
    expect(reviewService.saveAllCalls, 1);
    expect(repService.parseCalls.single.trainingColor, isNull);
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

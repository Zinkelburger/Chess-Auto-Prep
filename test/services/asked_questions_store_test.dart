import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/services/asked_questions_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late File storeFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('asked_questions_test');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    storeFile = File('${tempDir.path}/${AskedQuestionsStore.defaultFileName}');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  test('an answer survives into a new store instance', () async {
    await AskedQuestionsStore().record(
      AskedQuestion.chapterLayout,
      subject: '/reps/Colle1/Main.pgn',
      answer: true,
      note: 'a course export · 26 chapters',
    );

    // A fresh instance re-reads the file rather than trusting memory.
    final reloaded = AskedQuestionsStore();
    expect(
      await reloaded.boolAnswerFor(
        AskedQuestion.chapterLayout,
        subject: '/reps/Colle1/Main.pgn',
      ),
      isTrue,
    );
    final stored = await reloaded.answerFor(
      AskedQuestion.chapterLayout,
      subject: '/reps/Colle1/Main.pgn',
    );
    expect(stored!.note, 'a course export · 26 chapters');
    expect(stored.askedUtc.isUtc, isTrue);
  });

  test('answers are per subject; an unasked subject stays null', () async {
    final store = AskedQuestionsStore();
    await store.record(
      AskedQuestion.chapterLayout,
      subject: '/reps/A.pgn',
      answer: false,
    );

    expect(
      await store.boolAnswerFor(
        AskedQuestion.chapterLayout,
        subject: '/reps/A.pgn',
      ),
      isFalse,
    );
    expect(
      await store.boolAnswerFor(
        AskedQuestion.chapterLayout,
        subject: '/reps/B.pgn',
      ),
      isNull,
      reason: 'another file has not been asked yet',
    );
  });

  test('forget makes the question askable again', () async {
    final store = AskedQuestionsStore();
    await store.record(
      AskedQuestion.chapterLayout,
      subject: '/reps/A.pgn',
      answer: true,
    );
    await store.forget(AskedQuestion.chapterLayout, subject: '/reps/A.pgn');

    expect(
      await store.boolAnswerFor(
        AskedQuestion.chapterLayout,
        subject: '/reps/A.pgn',
      ),
      isNull,
    );
    expect(
      await AskedQuestionsStore().boolAnswerFor(
        AskedQuestion.chapterLayout,
        subject: '/reps/A.pgn',
      ),
      isNull,
      reason: 'the removal reached the file, not just the cache',
    );
  });

  test('the file is readable, versioned JSON', () async {
    await AskedQuestionsStore().record(
      AskedQuestion.chapterLayout,
      subject: '/reps/A.pgn',
      answer: true,
    );

    final decoded =
        jsonDecode(await storeFile.readAsString()) as Map<String, dynamic>;
    expect(decoded['version'], 1);
    expect(
      (decoded['answers'] as Map)['chapterLayout'],
      contains('/reps/A.pgn'),
    );
  });

  test('a corrupt file is ignored instead of blocking the prompt', () async {
    await storeFile.writeAsString('{not json at all');

    final store = AskedQuestionsStore();
    expect(
      await store.boolAnswerFor(
        AskedQuestion.chapterLayout,
        subject: '/reps/A.pgn',
      ),
      isNull,
    );

    // …and writing over it repairs the file.
    await store.record(
      AskedQuestion.chapterLayout,
      subject: '/reps/A.pgn',
      answer: true,
    );
    expect(
      await AskedQuestionsStore().boolAnswerFor(
        AskedQuestion.chapterLayout,
        subject: '/reps/A.pgn',
      ),
      isTrue,
    );
  });
}

import 'package:chess_auto_prep/chess/training/training_options.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/features/trainer/trainer.dart';
import 'package:chess_auto_prep/features/trainer/training_scope.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/settings.dart';
import 'package:chess_auto_prep/storage/settings_store.dart';
import 'package:chess_auto_prep/workspace/engine_analysis.dart';
import 'package:chess_auto_prep/workspace/repertoire_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/books_fixture.dart';
import '../../support/scripted_files.dart';
import '../../support/scripted_progress.dart';
import '../../support/scripted_store.dart';
import '../../support/session_fixture.dart';

const _main = '// Color: White\n[Event "First"]\n\n1. e4 e5 *';
const _other = '// Color: White\n[Event "Second"]\n\n1. d4 d5 *';

void main() {
  late SessionFixture session;
  late ScriptedFiles files;
  late ScriptedProgress progress;
  late EngineAnalysis analysis;
  late RepertoireCatalog catalog;
  late SettingsStore settings;
  late Trainer trainer;

  setUp(() async {
    session = await openSession(_main);
    session.store.documents[ref('KID', 'Other')] = Opened(
      _other,
      scriptedRevision(_other),
    );
    files = ScriptedFiles(
      listing: Repertoires([
        folder('KID', ['Main', 'Other']),
      ]),
    );
    progress = ScriptedProgress();
    analysis = EngineAnalysis(
      session.session,
      () async => const StartFailed('test'),
    );
    catalog = RepertoireCatalog(files: files, root: '/repertoires');
    await catalog.refresh();
    settings = SettingsStore();
    trainer = Trainer(
      session: session.session,
      chapters: ScopeReader(files: files, documents: session.store),
      files: progress,
      analysis: analysis,
      catalog: catalog,
      settings: settings,
      time: (now: () => DateTime.utc(2026), jitter: () => 0),
      books: booksWith(),
    );
    trainer.selection.choose(catalog.repertoires.single);
    await trainer.reload();
  });

  tearDown(() {
    trainer.dispose();
    settings.dispose();
    catalog.dispose();
    analysis.dispose();
    session.dispose();
  });

  test('repertoire loads all chapters without requiring a selected line', () {
    expect(trainer.scopeLines.map((l) => l.name), ['First', 'Second']);
    expect(trainer.learnCount, 2);
    trainer.learn();
    expect(trainer.lesson!.line.name, 'First');
    expect(trainer.lesson!.left, 1);
  });

  test(
    'completed lines stay learned after settings reload and browsing elsewhere',
    () async {
      final ready = trainer.state as TrainerReady;
      await ready.progress.mark([ready.lines.first], known: true);
      final saved = Settings.fromJson(settings.value.toJson());
      trainer.selection.followDocument();
      await settings.update(saved);
      trainer.selection.enter(null);
      await trainer.reload();
      expect(trainer.selection.root, '/repertoires/KID');
      trainer.learn();
      expect(trainer.lesson!.line.name, 'Second');
      expect(trainer.lesson!.left, 0);
    },
  );

  test(
    'due, all learned and selected review queues respect the chosen scope',
    () async {
      final ready = trainer.state as TrainerReady;
      await ready.progress.mark(ready.lines, known: true);
      expect(trainer.reviewCount, 0);
      trainer.selection.update(trainer.options.copyWith(reviewAll: true));
      expect(trainer.reviewCount, 2);
      trainer.selection.select(chapter: ready.chapters.last.ref);
      expect(trainer.reviewCount, 1);
      trainer.selection.select();
      trainer.selection.chooseLines(true);
      expect(trainer.reviewCount, 0);
      trainer.selection.pick(ready.lines.last.key, true);
      trainer.review();
      expect(trainer.lesson!.line.name, 'Second');
      expect(trainer.lesson!.left, 0);
    },
  );

  test(
    'chapter pauses preserve line pauses and apply after settings roundtrip',
    () async {
      final ready = trainer.state as TrainerReady;
      final first = ready.lines.first;
      await ready.progress.setExcluded(first, excluded: true);
      trainer.selection.pauseScope(true, chapter: ready.chapters.last.ref);
      expect(trainer.learnCount, 0);
      final saved = Settings.fromJson(settings.value.toJson());
      expect(saved.training.pausedScopes, trainer.options.pausedScopes);
      trainer.selection.pauseScope(true);
      trainer.selection.pauseScope(false);
      expect(
        trainer.learnCount,
        0,
        reason: 'resuming the repertoire keeps child pauses',
      );
      trainer.selection.pauseScope(false, chapter: ready.chapters.last.ref);
      expect(trainer.learnCount, 1);
      expect(ready.progress.reviewOf(first).excluded, isTrue);
      await ready.progress.mark([first], known: true);
      expect(ready.progress.reviewOf(first).untrained, isFalse);
      expect(ready.progress.reviewOf(first).excluded, isTrue);
    },
  );

  test(
    'browsing another chapter does not replace repertoire or scope',
    () async {
      final ready = trainer.state as TrainerReady;
      trainer.selection.select(chapter: ready.chapters.first.ref);
      await session.session.open(ref('KID', 'Other'));
      expect(trainer.selection.chapter, ready.chapters.first.ref);
      expect(trainer.scopeLines.single.name, 'First');
      expect((trainer.state as TrainerReady).chapters, hasLength(2));
    },
  );

  test('old settings load with no repertoire chosen and due review', () {
    final options = TrainingOptions.fromJson({'rateReviews': true});
    expect(options.repertoirePath, isEmpty);
    expect(options.reviewAll, isFalse);
    expect(options.pausedScopes, isEmpty);
    expect(options.rateReviews, isTrue);
  });
}

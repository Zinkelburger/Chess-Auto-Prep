import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/net/remote_queue.dart';
import 'package:chess_auto_prep/storage/audit_store.dart';
import 'package:chess_auto_prep/storage/eval_cache.dart';
import 'package:chess_auto_prep/storage/settings_store.dart';
import 'package:chess_auto_prep/workspace/chapter_audit.dart';
import 'package:chess_auto_prep/workspace/engine_analysis.dart';
import 'package:chess_auto_prep/workspace/engine_jobs.dart';
import 'package:chess_auto_prep/workspace/game_review.dart';
import 'package:chess_auto_prep/workspace/gap_hunt.dart';
import 'package:chess_auto_prep/workspace/replies.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/audit_fixture.dart';
import '../support/scripted_engine.dart';
import '../support/scripted_files.dart';
import '../support/session_fixture.dart';

/// The heavy engine jobs share one machine: a game review and a chapter
/// audit never run at once, and the board engines wait while either runs.
void main() {
  late SessionFixture chapter;
  late SessionFixture game;
  late EngineAnalysis board;
  late EngineAnalysis analysisTab;
  late EngineJobs jobs;
  late SettingsStore settings;
  late AuditStore store;
  late EvalCache cache;
  late ScriptedEngine reviewEngine;
  late int reviewLaunches;
  late ChapterAudit audit;
  late GameReview review;

  setUp(() async {
    chapter = await openSession(auditChapter);
    game = await openSession(
      '[Event "Game"]\n[Result "*"]\n\n1. e4 e5 *',
      name: 'Game',
    );
    board = EngineAnalysis(
      chapter.session,
      () async => Started(ScriptedEngine()),
    );
    analysisTab = EngineAnalysis(
      game.session,
      () async => Started(ScriptedEngine()),
    );
    jobs = EngineJobs(board, analysisTab: analysisTab);
    settings = SettingsStore();
    store = AuditStore.inMemory();
    cache = EvalCache.inMemory();
    reviewEngine = ScriptedEngine();
    reviewLaunches = 0;
    audit = ChapterAudit(
      session: chapter.session,
      jobs: jobs,
      launch: () async => Started(TableEngine(auditTable())),
      evalCache: () => cache,
      store: () => store,
      model: ReplyModel(policy: const AuditShares(), settings: settings),
      settings: settings,
      answers: RepertoireAnswers(
        files: ScriptedFiles(),
        documents: chapter.store,
      ),
      lookups: RemoteQueue.none(),
    );
    review = GameReview(
      session: game.session,
      jobs: jobs,
      launch: () async {
        reviewLaunches++;
        return Started(reviewEngine);
      },
    );
  });

  tearDown(() {
    review.dispose();
    audit.dispose();
    jobs.dispose();
    analysisTab.dispose();
    board.dispose();
    settings.dispose();
    store.close();
    cache.close();
    game.dispose();
    chapter.dispose();
  });

  test('a game review does not start while an audit holds the machine; the '
      'board engines wait for the audit', () async {
    final auditing = audit.start();
    expect(board.paused, isTrue);
    expect(analysisTab.paused, isTrue, reason: 'the Analysis tab waits too');

    await review.start();
    expect(review.running, isFalse);
    expect(review.problem, isNotNull);
    expect(reviewLaunches, 0, reason: 'no second Stockfish beside the audit');

    expect(await auditing, isNull);
    expect(jobs.heldByOther(review), isFalse);
    expect(board.paused, isFalse);
    expect(analysisTab.paused, isFalse);
  });

  test('an audit does not start while a game review holds the machine, and '
      'can once the review ends', () async {
    final reviewing = review.start();
    await pumpEventQueue();
    expect(review.running, isTrue);
    expect(reviewLaunches, 1);
    expect(audit.canStart, isFalse);
    expect(await audit.start(), contains('is running.'));
    expect(audit.running, isFalse);

    review.stop();
    reviewEngine.current.end();
    await reviewing;
    expect(review.running, isFalse);
    expect(jobs.heldByOther(audit), isFalse, reason: 'released in finally');
    expect(audit.canStart, isTrue);
  });
}

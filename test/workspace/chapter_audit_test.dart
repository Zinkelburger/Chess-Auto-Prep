import 'dart:async';
import 'dart:io';

import 'package:chess_auto_prep/chess/audit/chapter_audit.dart';
import 'package:chess_auto_prep/chess/pgn/analysis_board.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/net/remote_queue.dart';
import 'package:chess_auto_prep/storage/audit_store.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/storage/eval_cache.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/settings_store.dart';
import 'package:chess_auto_prep/workspace/chapter_audit.dart';
import 'package:chess_auto_prep/workspace/engine_analysis.dart';
import 'package:chess_auto_prep/workspace/engine_jobs.dart';
import 'package:chess_auto_prep/workspace/gap_hunt.dart';
import 'package:chess_auto_prep/workspace/replies.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/audit_fixture.dart';
import '../support/scripted_engine.dart';
import '../support/scripted_files.dart';
import '../support/scripted_store.dart';
import '../support/session_fixture.dart';

/// Another White chapter of the repertoire: it answers 1...e6.
const french = '''
// Color: White

[Event "French"]
[Result "*"]

1. e4 e6 2. d4 *
''';

void main() {
  late SessionFixture fixture;
  late EngineAnalysis analysis;
  late EngineJobs jobs;
  late ScriptedFiles files;
  late SettingsStore settings;
  late AuditStore store;
  late EvalCache cache;
  late TableEngine engine;
  late int launches;

  setUp(() async {
    fixture = await openSession(auditChapter);
    analysis = EngineAnalysis(
      fixture.session,
      () async => Started(ScriptedEngine()),
    );
    jobs = EngineJobs(analysis);
    files = ScriptedFiles();
    settings = SettingsStore();
    store = AuditStore.inMemory();
    cache = EvalCache.inMemory();
    engine = TableEngine(auditTable());
    launches = 0;
  });

  tearDown(() {
    jobs.dispose();
    analysis.dispose();
    settings.dispose();
    store.close();
    cache.close();
    fixture.dispose();
  });

  ChapterAudit auditWith({
    RemoteQueue? lookups,
    Future<EngineStart> Function()? launch,
    double e6 = 0.01,
  }) {
    final audit = ChapterAudit(
      session: fixture.session,
      jobs: jobs,
      launch:
          launch ??
          () async {
            launches++;
            return Started(engine);
          },
      evalCache: () => cache,
      store: () => store,
      model: ReplyModel(
        policy: AuditShares(e6: e6),
        settings: settings,
      ),
      settings: settings,
      answers: RepertoireAnswers(files: files, documents: fixture.store),
      lookups: lookups ?? RemoteQueue.none(),
    );
    addTearDown(audit.dispose);
    return audit;
  }

  test('finds a losing move of ours and a good reply the chapter and the '
      'model both miss, mistakes first', () async {
    final audit = auditWith();
    expect(await audit.start(), isNull);
    expect(audit.state, isA<AuditDone>());
    expect((audit.state as AuditDone).complete, isTrue);
    final findings = audit.findings;
    expect(findings.map((f) => '${f.runtimeType} ${f.san}'), [
      'WeakMove Nc3',
      'StrongReply e6',
    ], reason: 'a mistake before a reply more often met');
    final weak = findings.first as WeakMove;
    expect(weak.lossCp, 130);
    expect(weak.bestSan, 'Nf3');
    expect(weak.reach, closeTo(0.3, 1e-9), reason: "the model's 30% for c5");
    expect(engine.quitCalled, isTrue, reason: 'the engine is let go');
    expect(analysis.paused, isFalse, reason: 'the board engine comes back');
  });

  test('a reply the Replies tab lists as a gap is left to it', () async {
    final audit = auditWith(e6: 0.04);
    await audit.start();
    expect(audit.findings.map((f) => f.san), [
      'Nc3',
    ], reason: '4% of games clears the 1-in-50 floor: a gap, not the audit');
  });

  test('a reply a sibling chapter answers is not reported', () async {
    final sibling = chapterRef('KID', 'French');
    fixture.store.documents[sibling] = Opened(french, scriptedRevision(french));
    files.listing = Repertoires([
      folder('KID', ['Main', 'French']),
    ]);
    final audit = auditWith();
    await audit.start();
    expect(audit.findings.map((f) => f.san), ['Nc3']);
  });

  test('no audit starts while another engine job holds the machine, and '
      'one may once it is given back', () async {
    final audit = auditWith();
    final search = Object();
    jobs.take(search, 'Paused while searching');
    expect(audit.canStart, isFalse);
    expect(await audit.start(), isNotNull);
    var told = 0;
    audit.addListener(() => told++);
    jobs.release(search);
    expect(told, 1);
    expect(audit.canStart, isTrue);
  });

  test('auditing again asks the engine nothing it was asked before', () async {
    final audit = auditWith();
    await audit.start();
    final asked = engine.asked.length;
    await audit.start();
    expect(engine.asked.length, asked);
    expect(launches, 1, reason: 'kept lines and cached scores answer all');
    expect(audit.findings, hasLength(2));
  });

  test('a dismissed finding stays aside, on the next run, for a new owner '
      'and under a new name for the chapter, until restored', () async {
    final audit = auditWith();
    await audit.start();
    final reply = audit.findings.whereType<StrongReply>().single;
    audit.dismiss(reply);
    expect(audit.findings.map((f) => f.san), ['Nc3']);
    expect(audit.dismissedCount, 1);
    // The chapter renamed: the same moves in a file of another name.
    final renamed = chapterRef('KID', 'Renamed');
    fixture.store.documents[renamed] = Opened(
      auditChapter,
      scriptedRevision(auditChapter),
    );
    await fixture.session.open(renamed);
    final again = auditWith();
    await again.start();
    expect(again.findings.map((f) => f.san), ['Nc3']);
    again.restoreDismissed();
    expect(again.findings, hasLength(2));
  });

  test('a finding goes to the position before its move, and one the user '
      'fixes drops out with no new run', () async {
    final audit = auditWith();
    await audit.start();
    final reply = audit.findings.whereType<StrongReply>().single;
    audit.goTo(reply);
    expect(fixture.session.fen, after('e2e4'));
    fixture.session.playMove('e7e6');
    expect(audit.findings.map((f) => f.san), ['Nc3']);
  });

  test(
    'Stop keeps what was found so far; another chapter forgets it',
    () async {
      final gate = Completer<void>();
      engine.hold = gate.future;
      final audit = auditWith();
      final run = audit.start();
      await pumpEventQueue();
      audit.stop();
      gate.complete();
      await run;
      final done = audit.state as AuditDone;
      expect(done.complete, isFalse);
      expect(done.checked, lessThan(done.of));
      await fixture.session.showAnalysisBoard(
        analysisBoard(side: Side.white, root: after('e2e4')),
      );
      expect(audit.state, isA<AuditIdle>());
      expect(audit.findings, isEmpty);
    },
  );

  test('with ChessDB on, a good reply only it knows is named as its', () async {
    final audit = auditWith(
      lookups: RemoteQueue(
        MockClient((request) async {
          final board = request.url.queryParameters['board'];
          return http.Response(
            board == after('e2e4').value
                ? 'move:e7e5,score:-30|move:b7b6,score:-45'
                : 'unknown',
            200,
          );
        }),
      ),
    )..askChessDb = true;
    await audit.start();
    final fromDb = audit.findings.whereType<StrongReply>().where(
      (r) => r.fromChessDb,
    );
    expect(fromDb.map((r) => r.san), ['b6']);
    expect((audit.state as AuditDone).complete, isTrue);
  });

  test('a ChessDB outage leaves the audit incomplete, not done', () async {
    final audit = auditWith(
      lookups: RemoteQueue(MockClient((_) async => http.Response('', 503))),
    )..askChessDb = true;
    await audit.start();
    final done = audit.state as AuditDone;
    expect(done.checked, done.of, reason: 'the engine still checked all');
    expect(done.chessDbDropped, isTrue);
    expect(done.complete, isFalse);
  });

  test(
    'no engine is a failure said once, and the board engine comes back',
    () async {
      final audit = auditWith(
        launch: () async => const StartFailed('Stockfish is not installed'),
      );
      await audit.start();
      expect((audit.state as AuditFailed).reason, 'Stockfish is not installed');
      expect(analysis.paused, isFalse);
    },
  );

  test('an engine that dies partway leaves the audit incomplete, not '
      'done', () async {
    engine.dieAfter = 2;
    final audit = auditWith();
    await audit.start();
    final done = audit.state as AuditDone;
    expect(done.complete, isFalse);
    expect(done.checked, lessThan(done.of));
    expect(analysis.paused, isFalse, reason: 'the board engine comes back');
  });

  test('auditing again after the engine died asks only what it was not '
      'told, and finishes', () async {
    engine.dieAfter = 2;
    final audit = auditWith();
    await audit.start();
    final answered = engine.asked.take(2).toSet();
    engine = TableEngine(auditTable());
    await audit.start();
    expect(engine.asked, isNotEmpty);
    expect(engine.asked.toSet().intersection(answered), isEmpty);
    expect((audit.state as AuditDone).complete, isTrue);
    expect(audit.findings, hasLength(2));
  });

  test('an audit overtaken by another chapter keeps the machine until its '
      'engine is gone, so a new audit cannot run beside it', () async {
    final gates = <Completer<void>>[];
    final engines = <TableEngine>[];
    final aliveAtLaunch = <int>[];
    final audit = auditWith(
      launch: () async {
        aliveAtLaunch.add(engines.where((e) => !e.quitCalled).length);
        final gate = Completer<void>();
        gates.add(gate);
        final started = TableEngine(auditTable())..hold = gate.future;
        engines.add(started);
        return Started(started);
      },
    );
    final first = audit.start();
    await pumpEventQueue();
    expect(gates, hasLength(1));

    final sibling = chapterRef('KID', 'French');
    fixture.store.documents[sibling] = Opened(french, scriptedRevision(french));
    await fixture.session.open(sibling);
    expect(audit.state, isA<AuditIdle>());
    expect(audit.canStart, isFalse, reason: "the old run's engine still runs");
    expect(await audit.start(), 'Wait for the engine job under way to finish.');
    expect(jobs.heldByOther(Object()), isTrue);
    expect(analysis.paused, isTrue);

    gates.single.complete();
    await first;
    expect(audit.canStart, isTrue);
    expect(analysis.paused, isFalse);

    final second = audit.start();
    await pumpEventQueue();
    expect(gates, hasLength(2));
    expect(jobs.heldByOther(Object()), isTrue);
    expect(analysis.paused, isTrue);
    gates.last.complete();
    await second;
    expect(audit.state, isA<AuditDone>());
    expect(jobs.heldByOther(Object()), isFalse);
    expect(analysis.paused, isFalse);
    expect(aliveAtLaunch, [0, 0], reason: 'one audit engine at a time');
  });

  test('a dismissal the store cannot keep still hides the finding, and '
      'says it will not last', () async {
    final support = await Directory.systemTemp.createTemp('chapter_audit');
    addTearDown(() => support.delete(recursive: true));
    await File(
      '${support.path}/audit_dismissed.db',
    ).writeAsString('not a database, not even close to one');
    store.close();
    store = AuditStore.open(support);
    final audit = auditWith();
    await audit.start();
    expect(audit.dismissalsNotKept, isFalse);
    final reply = audit.findings.whereType<StrongReply>().single;
    audit.dismiss(reply);
    expect(audit.findings.map((f) => f.san), ['Nc3']);
    expect(audit.dismissalsNotKept, isTrue);
  });
}

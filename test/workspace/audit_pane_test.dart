import 'dart:io';

import 'package:chess_auto_prep/chess/audit/chapter_audit.dart';
import 'package:chess_auto_prep/chess/generation/eval.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/net/remote_queue.dart';
import 'package:chess_auto_prep/storage/audit_store.dart';
import 'package:chess_auto_prep/storage/eval_cache.dart';
import 'package:chess_auto_prep/storage/settings_store.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:chess_auto_prep/workspace/audit_pane.dart';
import 'package:chess_auto_prep/workspace/chapter_audit.dart';
import 'package:chess_auto_prep/workspace/engine_analysis.dart';
import 'package:chess_auto_prep/workspace/engine_jobs.dart';
import 'package:chess_auto_prep/workspace/gap_hunt.dart';
import 'package:chess_auto_prep/workspace/replies.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/audit_fixture.dart';
import '../support/scripted_engine.dart';
import '../support/scripted_files.dart';
import '../support/session_fixture.dart';

void main() {
  late SessionFixture fixture;
  late EngineAnalysis analysis;
  late EngineJobs jobs;
  late SettingsStore settings;
  late AuditStore store;
  late EvalCache cache;
  late ChapterAudit audit;

  ChapterAudit auditOver(RemoteQueue lookups) => ChapterAudit(
    session: fixture.session,
    jobs: jobs,
    launch: () async => Started(TableEngine(auditTable())),
    evalCache: () => cache,
    store: () => store,
    model: ReplyModel(policy: const AuditShares(), settings: settings),
    settings: settings,
    answers: RepertoireAnswers(
      files: ScriptedFiles(),
      documents: fixture.store,
    ),
    lookups: lookups,
  );

  setUp(() async {
    fixture = await openSession(auditChapter);
    analysis = EngineAnalysis(
      fixture.session,
      () async => Started(ScriptedEngine()),
    );
    settings = SettingsStore();
    store = AuditStore.inMemory();
    cache = EvalCache.inMemory();
    jobs = EngineJobs(analysis);
    audit = auditOver(RemoteQueue.none());
  });

  tearDown(() {
    audit.dispose();
    jobs.dispose();
    analysis.dispose();
    settings.dispose();
    store.close();
    cache.close();
    fixture.dispose();
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: AuditPane(audit: audit, session: fixture.session),
        ),
      ),
    );
  }

  Future<void> runAudit(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(FilledButton, 'Audit'));
    await tester.runAsync(() async {
      while (audit.running) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
    await tester.pump();
  }

  testWidgets('Audit lists what it found; a row goes to its position and × '
      'puts it aside until Restore', (tester) async {
    await pump(tester);
    await runAudit(tester);
    expect(find.text('Checked 4 positions · 2 findings'), findsOneWidget);
    expect(find.textContaining('Strong reply'), findsOneWidget);
    expect(find.textContaining('Mistake'), findsOneWidget);
    expect(find.textContaining('loses 1.3 · best Nf3'), findsOneWidget);

    await tester.tap(find.textContaining('Mistake'));
    await tester.pump();
    expect(fixture.session.fen, after('e2e4 c7c5'));

    await tester.tap(find.byTooltip('Dismiss').last);
    await tester.pump();
    expect(find.textContaining('Strong reply'), findsNothing);
    expect(find.text('1 dismissed'), findsOneWidget);
    await tester.tap(find.text('Restore'));
    await tester.pump();
    expect(find.textContaining('Strong reply'), findsOneWidget);
    expect(find.text('1 dismissed'), findsNothing);
  });

  testWidgets('a dismissal that cannot be saved says it lasts only until '
      'the app closes', (tester) async {
    final support = Directory.systemTemp.createTempSync('audit_pane');
    addTearDown(() => support.deleteSync(recursive: true));
    File(
      '${support.path}/audit_dismissed.db',
    ).writeAsStringSync('not a database, not even close to one');
    store.close();
    store = AuditStore.open(support);
    await pump(tester);
    await runAudit(tester);
    const warning =
        'Dismissals could not be saved; they last only until you audit '
        'again.';
    expect(find.text(warning), findsNothing);
    await tester.tap(find.byTooltip('Dismiss').last);
    await tester.pump();
    expect(find.textContaining('Strong reply'), findsNothing);
    expect(find.text(warning), findsOneWidget);
  });

  testWidgets('a run that is not complete says so and offers to finish, '
      'though every position was checked', (tester) async {
    audit.dispose();
    audit = auditOver(
      RemoteQueue(MockClient((_) async => http.Response('', 503))),
    );
    await pump(tester);
    await tester.tap(find.widgetWithText(FilterChip, 'ChessDB'));
    await tester.pump();
    await runAudit(tester);
    expect((audit.state as AuditDone).complete, isFalse);
    expect(
      find.text(
        'Checked 4 positions · 2 findings · ChessDB stopped answering · '
        'Audit again to finish',
      ),
      findsOneWidget,
    );
  });

  test('a missed mate or a mate walked into is said as a mate, never as '
      'pawns', () {
    WeakMove weak(int best, int played) => WeakMove(
      fen: after('e2e4 c7c5'),
      sans: const ['e4', 'c5'],
      san: 'Nc3',
      uci: 'b1c3',
      reach: null,
      best: Eval(best),
      played: Eval(played),
      bestSan: 'Nf3',
    );
    expect(auditNumbers(weak(9997, 40)), 'misses mate · best Nf3');
    expect(auditNumbers(weak(40, -9996)), 'allows mate · best Nf3');
    expect(auditNumbers(weak(40, -90)), 'loses 1.3 · best Nf3');
  });
}

import 'package:chess_auto_prep/v2/app/exit_guard.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/diagnostics/log.dart';
import 'package:chess_auto_prep/v2/app/shell.dart';
import 'package:chess_auto_prep/v2/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/v2/features/library/library.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/workspace/save_state.dart';
import 'package:chess_auto_prep/v2/workspace/session_results.dart';
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:chess_auto_prep/v2/workspace/document_saver.dart';
import 'package:chess_auto_prep/v2/workspace/document_session.dart';
import 'package:chess_auto_prep/v2/workspace/engine_analysis.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';
import '../support/scripted_files.dart';
import '../support/scripted_store.dart';

void main() {
  final kid = ref('KID', 'Main');
  final benko = ref('benko', 'Main');
  late ScriptedFiles files;
  late ScriptedDocumentStore store;
  late Library library;
  late DocumentSaver saver;
  late DocumentSession session;
  late EngineAnalysis analysis;
  late _Question question;
  late ExitGuard leaving;

  setUp(() {
    files = ScriptedFiles(
      listing: Repertoires([
        folder('benko', ['Main']),
        folder('KID', ['Main']),
      ]),
    );
    store = ScriptedDocumentStore()
      ..documents[kid] = Opened(blackChapter, scriptedRevision(blackChapter))
      ..documents[benko] = Opened(
        '// Color: White\n',
        scriptedRevision('// Color: White\n'),
      );
    saver = DocumentSaver(store, delay: Duration.zero);
    session = DocumentSession(store, saver);
    library = Library(
      files: files,
      documents: store,
      session: session,
      saver: saver,
      root: '/repertoires',
    );
    analysis = EngineAnalysis(
      session,
      () async => const StartFailed('no engine in this test'),
    );
    question = _Question();
    leaving = ExitGuard(
      saver: saver,
      question: question,
      saveCopy: () async {
        final written = await session.copyAside('Main copy');
        return written is CopySaved ? written.name : null;
      },
      wait: const Duration(milliseconds: 20),
    );
  });

  tearDown(() {
    analysis.dispose();
    library.dispose();
    session.dispose();
    saver.dispose();
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 800));
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Shell(
          library: library,
          session: session,
          saver: saver,
          analysis: analysis,
          leaving: leaving,
        ),
      ),
    );
    await library.refresh();
    await tester.pumpAndSettle();
    // The rows start closed; the chapters are what this test clicks.
    await tester.tap(find.text('benko'));
    await tester.tap(find.text('KID'));
    await tester.pumpAndSettle();
  }

  testWidgets('opening a chapter puts it in the workspace', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Main').last);
    await tester.pump();
    expect(session.source, kid);
    expect(session.chapter?.gameCount, 2);
    expect(find.textContaining('Black · 2 lines'), findsOneWidget);
  });

  testWidgets('the later of two clicks wins, whichever read finishes first', (
    tester,
  ) async {
    await pump(tester);
    store.hold = true;
    await tester.tap(find.text('Main').last); // KID
    await tester.tap(find.text('Main').first); // benko
    expect(store.waiting, 2);
    store.releaseAll(); // KID's read answers before benko's
    await tester.pump();
    expect(session.source, benko);
    // The stale KID answer must not have replaced benko.
    await tester.pump();
    expect(session.source, benko);
  });

  testWidgets('a chapter that vanished is reported, not opened', (
    tester,
  ) async {
    await pump(tester);
    store.documents.clear();
    await tester.tap(find.text('Main').last);
    await tester.pump();
    expect(session.chapter, isNull);
    expect(find.text('Main is no longer on disk'), findsOneWidget);
  });
  testWidgets('another chapter is not opened over a frozen document until '
      'the user says so', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Main').last); // KID
    await tester.pumpAndSettle();
    store.saves.add(
      const SaveRefused('game 3 would change but the edit was to game 1'),
    );
    session.setComment(NodePath.of([0]), 'frozen words');
    await tester.pumpAndSettle();
    expect(saver.state, isA<SaveStopped>());

    question.answer = DraftChoice.keepWaiting;
    await tester.tap(find.text('Main').first); // benko
    await tester.pumpAndSettle();
    expect(question.asked.single, contains('was stopped'));
    expect(session.source, kid, reason: 'nothing opened over the words');
    expect(session.commentAt(NodePath.of([0])), contains('frozen words'));
  });

  testWidgets('leaving a frozen document anyway is logged', (tester) async {
    final entries = <LogEntry>[];
    void collect(LogEntry entry) => entries.add(entry);
    log.install(collect);
    addTearDown(() => log.remove(collect));
    await pump(tester);
    await tester.tap(find.text('Main').last); // KID
    await tester.pumpAndSettle();
    store.saves.add(const SaveRefused('game 3 would change'));
    session.setComment(NodePath.of([0]), 'frozen words');
    await tester.pumpAndSettle();

    question.answer = DraftChoice.closeAnyway;
    await tester.tap(find.text('Main').first); // benko
    await tester.pumpAndSettle();
    expect(session.source, benko);
    expect(
      entries
          .where((entry) => entry.level == LogLevel.warning)
          .map((entry) => entry.action),
      contains(contains('leave this document with unsaved words')),
    );
  });
  testWidgets('clicking the chapter that is already open asks nothing', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text('Main').last); // KID
    await tester.pumpAndSettle();
    store.saves.add(const SaveRefused('game 3 would change'));
    session.setComment(NodePath.of([0]), 'frozen words');
    await tester.pumpAndSettle();
    question.asked.clear();

    await tester.tap(find.text('Main').last); // KID again
    await tester.pumpAndSettle();
    expect(question.asked, isEmpty);
    expect(session.source, kid);
  });

  testWidgets('saving a copy on the way out says where the words went', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text('Main').last); // KID
    await tester.pumpAndSettle();
    store.saves.add(const SaveRefused('game 3 would change'));
    session.setComment(NodePath.of([0]), 'frozen words');
    await tester.pumpAndSettle();

    question.answer = DraftChoice.saveACopy;
    await tester.tap(find.text('Main').first); // benko
    await tester.pumpAndSettle();
    expect(session.source, benko, reason: 'the click still went through');
    expect(find.text('Saved a copy as Main copy.pgn'), findsOneWidget);
    expect(
      store.documents.keys.map((ref) => ref.path),
      contains('/repertoires/KID/Main copy.pgn'),
    );
  });
}

/// The question the shell puts before it leaves a document: it records what
/// it was asked and answers what the test set.
final class _Question implements DraftQuestion {
  DraftChoice? answer;
  final asked = <String>[];

  @override
  Future<DraftChoice?> put(DraftPrompt prompt) {
    asked.add(prompt.body);
    return Future<DraftChoice?>.value(answer);
  }

  @override
  void withdraw() {}
}

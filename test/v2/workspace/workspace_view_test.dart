import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:chess_auto_prep/v2/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/v2/workspace/document_saver.dart';
import 'package:chess_auto_prep/v2/workspace/document_session.dart';
import 'package:chess_auto_prep/v2/workspace/engine_analysis.dart';
import 'package:chess_auto_prep/v2/workspace/workspace_keys.dart';
import 'package:chess_auto_prep/v2/workspace/workspace_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';
import '../support/scripted_store.dart';
import '../support/session_fixture.dart';

void main() {
  late SessionFixture fixture;
  late DocumentSession session;
  late DocumentSaver saver;
  late EngineAnalysis analysis;

  /// The engine stays off; its pane has its own test.
  void startAnalysis() {
    analysis = EngineAnalysis(
      session,
      () async => const StartFailed('no engine in this test'),
    );
  }

  Future<void> pump(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 700));
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        // The keys belong above every column that edits the document, which
        // is where the shell puts them; here the workspace is the only one.
        home: Scaffold(
          body: WorkspaceKeys(
            session: session,
            child: WorkspaceView(
              session: session,
              saver: saver,
              analysis: analysis,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  setUp(() async {
    fixture = await openSession(blackChapter);
    session = fixture.session;
    saver = fixture.saver;
    startAnalysis();
  });

  tearDown(() {
    analysis.dispose();
    fixture.dispose();
  });

  testWidgets('shows the chapter, its lines and its variations', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Main'), findsOneWidget);
    expect(find.text('2 lines, 1 from another position'), findsOneWidget);
    expect(find.textContaining('c5'), findsOneWidget);
    expect(find.textContaining('Nc3'), findsOneWidget);
    expect(find.text('The Sicilian'), findsOneWidget);
    expect(find.textContaining('[%eval'), findsNothing);
  });

  testWidgets('clicking a variation move puts the cursor on it', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.textContaining('Nc3'));
    await tester.pump();
    expect(session.cursor, NodePath.of([0, 1]));
    expect(session.currentMove?.san, 'Nc3');
    // Two moves render as "2... Nc6"; walk on instead of picking one.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(session.cursor, NodePath.of([0, 1, 0]));
    await tester.tap(find.textContaining('cxd4'));
    await tester.pump();
    expect(session.cursor, NodePath.of([0, 0, 0, 0, 0]));
  });

  testWidgets('arrow keys walk the line', (tester) async {
    await pump(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(session.currentMove?.san, 'Nf3');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    expect(session.currentMove?.san, 'c5');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    expect(session.currentMove?.san, 'cxd4');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    expect(session.cursor.isRoot, isTrue);
  });

  testWidgets('typing in the comment keeps the arrows and Ctrl+Z', (
    tester,
  ) async {
    final sicilian = NodePath.of([0]);
    await pump(tester);
    session.goTo(sicilian);
    session.setComment(sicilian, 'Mine'); // one edit there is to take back
    await tester.pumpAndSettle();
    final field = find.byType(TextField);
    await tester.tap(field);
    await tester.enterText(field, 'Mine words');
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(session.cursor, sicilian, reason: 'the arrow moved the caret');
    final editing = tester.widget<EditableText>(find.byType(EditableText));
    expect(editing.controller.selection.baseOffset, 'Mine words'.length - 1);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(
      session.commentAt(sicilian),
      contains('Mine'),
      reason: 'Ctrl+Z belongs to the field, not the document',
    );
    expect(saver.canUndo, isTrue);
  });

  testWidgets('with nothing open it asks for a chapter', (tester) async {
    final empty = ScriptedDocumentStore();
    saver = DocumentSaver(empty, delay: Duration.zero);
    session = DocumentSession(empty, saver);
    analysis.dispose();
    startAnalysis();
    await pump(tester);
    expect(find.text('Open a chapter'), findsOneWidget);
    expect(find.text('No moves'), findsOneWidget);
  });
}

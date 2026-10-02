import 'package:chess_auto_prep/app/mode.dart';
import 'package:chess_auto_prep/workspace/audit_pane.dart';
import 'package:chess_auto_prep/workspace/engine_jobs.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/window_fixture.dart';

void main() {
  late WindowFixture w;
  setUp(() => w = WindowFixture());
  tearDown(() => w.dispose());

  testWidgets('grouped modes can be searched and selected by keyboard', (
    tester,
  ) async {
    await w.pumpShell(tester);
    await tester.tap(find.text('Repertoire builder'));
    await tester.pumpAndSettle();
    expect(find.text('Opponent preparation'), findsOneWidget);
    await tester.tap(find.text('Find a mode…'));
    await tester.pumpAndSettle();
    final field = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(field, 'Repertoire trainer');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(w.requests.mode, Mode.trainer);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pumpAndSettle();
    expect(w.requests.mode, Mode.repertoires);
  });

  testWidgets('named running task returns to its tool after a mode detour', (
    tester,
  ) async {
    await w.pumpShell(tester);
    final jobs = w.parts.workspace.jobs!;
    final owner = Object();
    jobs.take(owner, 'Auditing', kind: EngineJobKind.audit);
    await tester.pumpAndSettle();
    w.requests.switchTo(Mode.tactics);
    await tester.pumpAndSettle();
    expect(jobs.blockingMessage, contains('Chapter audit'));
    await tester.tap(find.text('Chapter audit · running'));
    await tester.pumpAndSettle();
    expect(w.requests.mode, Mode.repertoires);
    expect(find.byType(AuditPane), findsOneWidget);
    expect(jobs.activeKind, EngineJobKind.audit);
    jobs.release(Object());
    expect(jobs.activeKind, EngineJobKind.audit);
    jobs.release(owner);
    await tester.pumpAndSettle();
    expect(find.text('Chapter audit · running'), findsNothing);
  });
}

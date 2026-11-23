// The engine's lines under a Bughouse board: a row that sits says so, and
// a floated board goes when the rows are for another table.
import 'package:chess_auto_prep/chess/bughouse/hivemind.dart';
import 'package:chess_auto_prep/chess/bughouse/table.dart';
import 'package:chess_auto_prep/engines/hivemind_engine.dart';
import 'package:chess_auto_prep/features/bughouse/bughouse_lab.dart';
import 'package:chess_auto_prep/features/bughouse/bughouse_screen.dart';
import 'package:chess_auto_prep/features/bughouse/lab_engine.dart';
import 'package:chess_auto_prep/features/bughouse/lab_lines.dart';
import 'package:chess_auto_prep/features/bughouse/pocket.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_bughouse.dart';

void main() {
  late BughouseLab lab;
  late ScriptedHivemind hivemind;
  late LabEngine engine;

  void build() {
    lab = BughouseLab();
    hivemind = ScriptedHivemind();
    engine = LabEngine(
      lab: lab,
      passes: const [800],
      startEngine: () async => HivemindStarted(hivemind),
    );
    addTearDown(() {
      engine.dispose();
      lab.dispose();
    });
  }

  Future<void> pump(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: BughouseScreen(lab: lab, engine: engine),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> engineSays(
    WidgetTester tester,
    List<JointMove> pv, {
    Team team = Team.ab,
  }) async {
    hivemind.answer = (question) => question.team == team
        ? HivemindSearched(
            best: pv.first,
            lines: [JointLine(rank: 1, cp: -200, nodes: 800, pv: pv)],
          )
        : firstMoves(question);
    engine
      ..open()
      ..toggle();
    await tester.pumpAndSettle();
  }

  const sit = 'Sit: wait here rather than move';

  testWidgets('a row that moves does not say sit', (tester) async {
    build();
    await pump(tester);
    await engineSays(tester, const [
      JointMove('e2e4', null),
      JointMove('e7e5', null),
    ]);
    expect(find.text('1. e4'), findsOneWidget);
    expect(find.byTooltip(sit), findsNothing);
  });

  testWidgets('a row that sits on its board says so first', (tester) async {
    build();
    // A on move on board 1, B on board 2: A + B may sit on board 1.
    lab
      ..showBoards(LabBoards.two)
      ..loadDualFen(
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] w KQkq - 0 1|'
        'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR[] b KQkq - 0 1',
      );
    await pump(tester);
    await engineSays(tester, const [JointMove(null, 'd7d5')]);
    final board2 = tester.getRect(find.byType(BoardLineRows).at(1));
    final said = tester.getRect(find.byTooltip(sit));
    expect(said.right, lessThan(board2.left), reason: 'under board 1');
  });

  testWidgets('a floated board goes when the table changes under it', (
    tester,
  ) async {
    build();
    await pump(tester);
    await engineSays(tester, const [
      JointMove('e2e4', null),
      JointMove('e7e5', null),
    ]);
    final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await pointer.addPointer(location: Offset.zero);
    addTearDown(pointer.removePointer);
    await pointer.moveTo(tester.getCenter(find.text('e5')));
    await tester.pump(previewDelay * 2);
    expect(find.byType(BughousePreviewBoard), findsOneWidget);
    lab.play(BoardNumber.one, 'd2d4');
    // The frame the new rows are built in takes the board down; the next
    // one draws it gone.
    await tester.pump();
    await tester.pump();
    expect(find.byType(BughousePreviewBoard), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

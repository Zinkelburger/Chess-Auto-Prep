// The Bughouse screen's ↓ and ↑: the next and the previous game of the file
// open.
import 'package:chess_auto_prep/engines/hivemind_engine.dart';
import 'package:chess_auto_prep/features/bughouse/bughouse_lab.dart';
import 'package:chess_auto_prep/features/bughouse/bughouse_screen.dart';
import 'package:chess_auto_prep/features/bughouse/lab_engine.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_bughouse.dart';

void main() {
  testWidgets('↓ and ↑ walk the games of the file', (tester) async {
    final lab = BughouseLab();
    final engine = LabEngine(
      lab: lab,
      passes: const [800],
      startEngine: () async => HivemindStarted(ScriptedHivemind()),
    );
    addTearDown(() {
      engine.dispose();
      lab.dispose();
    });
    String game(int round) =>
        '[Event "Club night"]\n[Round "$round"]\n\n1A. e4 1a. d5 1-0\n\n';
    lab.pasteMoves(game(1) + game(2) + game(3), file: 'night.bpgn');
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
    expect(lab.gameAt, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(lab.gameAt, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(lab.gameAt, 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(lab.gameAt, 1);
  });
}

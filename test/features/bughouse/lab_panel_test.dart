// The column beside the Bughouse boards: the sit chips' words, the game row
// of a game without tags, and the score in the engine bar.
import 'package:chess_auto_prep/chess/bughouse/hivemind.dart';
import 'package:chess_auto_prep/engines/hivemind_engine.dart';
import 'package:chess_auto_prep/features/bughouse/bughouse_lab.dart';
import 'package:chess_auto_prep/features/bughouse/bughouse_screen.dart';
import 'package:chess_auto_prep/features/bughouse/lab_engine.dart';
import 'package:chess_auto_prep/features/bughouse/lab_lines.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_bughouse.dart';

void main() {
  late BughouseLab lab;
  late LabEngine engine;

  void build() {
    lab = BughouseLab();
    engine = LabEngine(
      lab: lab,
      passes: const [800],
      startEngine: () async => HivemindStarted(ScriptedHivemind()),
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

  testWidgets('with one board the sit chips name the colours, with two the '
      'teams', (tester) async {
    build();
    await pump(tester);
    expect(find.text('White may sit'), findsOneWidget);
    expect(
      find.byTooltip('White is up on the clock, so can wait rather than move'),
      findsOneWidget,
    );
    expect(
      find.byTooltip('Black is up on the clock, so can wait rather than move'),
      findsOneWidget,
    );
    lab.showBoards(LabBoards.two);
    await tester.pumpAndSettle();
    expect(find.text(ClockCase.abMaySit.label), findsOneWidget);
    expect(find.byTooltip(ClockCase.abMaySit.hint), findsOneWidget);
    expect(find.byTooltip(ClockCase.cdMaySit.hint), findsOneWidget);
  });

  testWidgets('a file whose first game has no tags still steps through its '
      'games', (tester) async {
    build();
    lab.pasteMoves(
      '1A. e4 1a. e5 *\n\n[Event "Club night"]\n\n1A. d4 1a. d5 *\n',
      file: 'night.bpgn',
    );
    expect(lab.game, isNull);
    expect(lab.gameCount, 2);
    await pump(tester);
    expect(find.text('of 2'), findsOneWidget);
  });

  testWidgets('the bar shows the score once the engine has searched', (
    tester,
  ) async {
    build();
    await pump(tester);
    Text barScore() => tester.widget<Text>(
      find
          .descendant(
            of: find.byTooltip(scoreHint(single: true)).first,
            matching: find.byType(Text),
          )
          .first,
    );
    expect(barScore().data, isEmpty);
    engine
      ..open()
      ..toggle();
    await tester.pumpAndSettle();
    final score = barScore().data!;
    expect(score, isNotEmpty);
    // The same score heads the best line under it.
    expect(find.text(score), findsAtLeastNWidgets(2));
  });
}

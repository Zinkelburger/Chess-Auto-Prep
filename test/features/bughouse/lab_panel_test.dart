// The column beside the Bughouse boards: the game row of a game without
// tags, and the score and search size in the engine bar.
import 'package:chess_auto_prep/engines/hypebeast_engine.dart';
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
      cores: 4,
      startEngine: () async => HypeBeastStarted(ScriptedHypeBeast()),
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

  testWidgets('the bar names HypeBeast and the size of the search', (
    tester,
  ) async {
    build();
    await pump(tester);
    expect(find.text('HypeBeast'), findsOneWidget);
    engine
      ..open()
      ..toggle();
    await tester.pumpAndSettle();
    expect(find.text('HypeBeast · 200 nodes'), findsOneWidget);
    lab.showBoards(LabBoards.two);
    await tester.pumpAndSettle();
    expect(find.text('HypeBeast · 400 nodes'), findsOneWidget);
    // Two boards: the bar's score is both boards' added, and says so.
    expect(find.byTooltip(scoreHint(single: false)), findsOneWidget);
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

// The Filter tab's rules in detail: the file's own headers offered as
// fields, a field or a rule typed by any of its names, All or Any only for
// two rules or more, the position filter removed from its chip, what can be
// done with the games found, one game counted as one, and the rule row's
// one-line layout from its width up.
import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/game_filter.dart';
import 'package:chess_auto_prep/features/pgn_viewer/filter_pane.dart';
import 'package:chess_auto_prep/ui/choice_field.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/viewer_fixture.dart';

const _withRound = '''
[Event "Club night"]
[Round "1"]
[White "Ann"]
[Black "Bob"]
[Result "1-0"]

1. e4 e5 1-0

[Event "Club night"]
[Round "2"]
[White "Cat"]
[Black "Ann"]
[Result "0-1"]

1. d4 d5 0-1
''';

const _oneGame = '''
[Event "Club night"]
[White "Ann"]
[Black "Bob"]
[Result "1-0"]

1. e4 e5 1-0
''';

void main() {
  late ViewerFixture fixture;

  Future<void> show(
    WidgetTester tester, {
    String text = _withRound,
    double width = 600,
  }) async {
    fixture = await viewerOver(text);
    addTearDown(fixture.dispose);
    await fixture.open();
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: ViewerFilterPane(
                viewer: fixture.viewer,
                filter: fixture.filter,
                onSaveToStudy: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  HeaderRule firstRule() => fixture.filter.filter.rules.first;

  Future<void> type(WidgetTester tester, String box, String text) async {
    await tester.enterText(find.widgetWithText(TextField, box), text);
    await tester.pumpAndSettle();
  }

  testWidgets('the file\'s own headers are offered as fields, once each', (
    tester,
  ) async {
    await show(tester);
    final options = tester
        .widget<ChoiceField>(find.byType(ChoiceField).first)
        .options;
    expect(options, contains('Round'));
    expect(options.where((o) => o == 'White'), hasLength(1));
  });

  testWidgets('a field is taken by its name in any case', (tester) async {
    await show(tester);
    await type(tester, 'Player', 'white RATING');
    expect(firstRule().field, 'WhiteElo');
  });

  testWidgets('a rule is taken by its label, its name, or >= and <=', (
    tester,
  ) async {
    await show(tester);
    Future<void> rule(String text) async {
      await tester.enterText(find.byType(TextField).at(1), text);
      await tester.pumpAndSettle();
    }

    await rule('equals');
    expect(firstRule().rule, FilterRule.equals);
    await rule('>=');
    expect(firstRule().rule, FilterRule.atLeast);
    await rule('<=');
    expect(firstRule().rule, FilterRule.atMost);
  });

  testWidgets('All or Any shows for two rules, and Any means any', (
    tester,
  ) async {
    await show(tester);
    expect(find.text('Any'), findsNothing);
    await tester.tap(find.text('Add rule'));
    await tester.pumpAndSettle();
    expect(find.text('All'), findsOneWidget);
    await tester.tap(find.text('Any'));
    await tester.pumpAndSettle();
    expect(fixture.filter.applied.any, isTrue);
  });

  testWidgets('the position filter comes off from its chip', (tester) async {
    await show(tester);
    fixture.filter.reaching(Fen.initial);
    await tester.pumpAndSettle();
    expect(fixture.filter.applied.position, isNotNull);
    await tester.tap(find.byTooltip('Remove position filter'));
    await tester.pumpAndSettle();
    expect(fixture.filter.applied.position, isNull);
  });

  testWidgets('the games found can be exported or added to a study; none '
      'found, neither', (tester) async {
    await show(tester);
    await type(tester, 'Value', 'Ann');
    bool on(String label) =>
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, label))
            .onPressed !=
        null;
    expect(on('Export games…'), isTrue);
    expect(on('Add games to study…'), isTrue);
    await type(tester, 'Ann', 'Nobody');
    expect(fixture.viewer.visible, isEmpty);
    expect(on('Export games…'), isFalse);
    expect(on('Add games to study…'), isFalse);
  });

  testWidgets('one game is counted as one', (tester) async {
    await show(tester, text: _oneGame);
    expect(find.text('1 game'), findsOneWidget);
  });

  testWidgets('a rule row on its full width keeps its value on the same line', (
    tester,
  ) async {
    await show(tester, width: filterRowWidth + Space.m + Space.s);
    final field = tester.getTopLeft(find.byType(ChoiceField).first);
    final value = tester.getTopLeft(find.byType(ChoiceField).at(2));
    expect(value.dy, field.dy);
  });
}

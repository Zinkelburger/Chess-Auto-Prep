import 'package:chess_auto_prep/chess/game_filter.dart';
import 'package:chess_auto_prep/features/pgn_viewer/filter_pane.dart';
import 'package:chess_auto_prep/features/pgn_viewer/player_side_choice.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/viewer_fixture.dart';

void main() {
  late ViewerFixture fixture;

  Future<void> pump(WidgetTester tester, Widget child, {double width = 600}) =>
      tester
          .pumpWidget(
            MaterialApp(
              theme: darkTheme(),
              home: Scaffold(
                body: SizedBox(width: width, child: child),
              ),
            ),
          )
          .then((_) => tester.pumpAndSettle());

  Widget pane() =>
      ViewerFilterPane(viewer: fixture.viewer, filter: fixture.filter);

  testWidgets('the Filter tab opens on one blank Field / Rule / Value row; '
      'a rule narrows the games, is counted and is removed', (tester) async {
    fixture = await viewerOver(threeGameFile);
    addTearDown(fixture.dispose);
    await fixture.open();
    await pump(tester, pane());
    expect(find.text('3 games'), findsOneWidget);
    expect(find.text('Player'), findsOneWidget, reason: 'one blank row');
    expect(find.text('contains'), findsOneWidget);
    expect(find.text('Clear'), findsNothing);
    expect(find.text('Export matching games…'), findsNothing);

    await tester.enterText(find.widgetWithText(TextField, 'Value'), 'Carlsen');
    await tester.pumpAndSettle();
    expect(find.text('1 of 3 games'), findsOneWidget);
    expect(fixture.viewer.visible, hasLength(1));
    expect(find.text('Export matching games…'), findsOneWidget);

    await tester.tap(find.byTooltip('Remove this rule'));
    await tester.pumpAndSettle();
    expect(fixture.filter.narrowing, isFalse);
    expect(find.text('3 games'), findsOneWidget);
  });

  testWidgets('a Moves rule takes a move sequence and keeps the games that '
      'play it', (tester) async {
    fixture = await viewerOver(threeGameFile);
    addTearDown(fixture.dispose);
    await fixture.open();
    await pump(tester, pane());
    await tester.enterText(find.widgetWithText(TextField, 'Player'), 'Moves');
    await tester.pumpAndSettle();
    final sequence = find.widgetWithText(TextField, 'e4 c5 … Nf3');
    expect(sequence, findsOneWidget, reason: 'the value box shows the form');
    await tester.enterText(sequence, '1.d4 … c4');
    await tester.pump(const Duration(milliseconds: 400));
    // The worker answers on the real clock; its answer lands on a pump.
    for (var i = 0; i < 500 && fixture.filter.busy; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.text('1 of 3 games'), findsOneWidget);
    expect(fixture.viewer.visible.single.$2.title, 'Ding, Liren – Giri, Anish');
  });

  testWidgets('a narrow pane puts the value under the field and the rule', (
    tester,
  ) async {
    fixture = await viewerOver(threeGameFile);
    addTearDown(fixture.dispose);
    await fixture.open();
    await pump(tester, pane(), width: 320);
    final field = tester.getRect(find.widgetWithText(TextField, 'Player'));
    final value = tester.getRect(find.widgetWithText(TextField, 'Value'));
    expect(value.top, greaterThan(field.bottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a followed player\'s games are kept by colour from the '
      'explorer\'s This file, as a rule the Filter tab shows', (tester) async {
    fixture = await viewerOver(_kasparov);
    addTearDown(fixture.dispose);
    await fixture.open();
    await pump(
      tester,
      Column(
        children: [
          PlayerSideChoice(viewer: fixture.viewer, filter: fixture.filter),
          Expanded(child: pane()),
        ],
      ),
    );
    expect(fixture.viewer.followed, 'Kasparov, Gary');
    expect(find.text('All 3'), findsOneWidget);
    expect(find.text('White 2'), findsOneWidget);
    expect(find.text('Black 1'), findsOneWidget);

    await tester.tap(find.text('Black 1'));
    await tester.pumpAndSettle();
    expect(sideKept(fixture.filter.applied, 'Kasparov, Gary'), Side.black);
    expect(fixture.viewer.visible, hasLength(1));
    expect(find.text('1 of 3 games'), findsOneWidget);
    expect(find.text('Black'), findsOneWidget, reason: 'the rule\'s field');

    await tester.tap(find.text('White 2'));
    await tester.pumpAndSettle();
    expect(fixture.filter.applied.active, hasLength(1));
    expect(fixture.viewer.visible, hasLength(2));

    await tester.tap(find.text('All 3'));
    await tester.pumpAndSettle();
    expect(fixture.filter.narrowing, isFalse);
  });

  testWidgets('a file that is nobody\'s collection offers no colour', (
    tester,
  ) async {
    fixture = await viewerOver(threeGameFile);
    addTearDown(fixture.dispose);
    await fixture.open();
    await pump(
      tester,
      PlayerSideChoice(viewer: fixture.viewer, filter: fixture.filter),
    );
    expect(find.byKey(const ValueKey('player-side')), findsNothing);
  });

  test('keeping a side leaves the other rules and replaces its own', () {
    const other = HeaderRule(field: 'ECO', value: 'B22');
    final white = keepingSide(
      const GameFilter(rules: [other]),
      'Kasparov, Gary',
      Side.white,
    );
    expect(white.rules, hasLength(2));
    expect(sideKept(white, 'kasparov, gary'), Side.white);
    final black = keepingSide(white, 'Kasparov, Gary', Side.black);
    expect(black.rules, hasLength(2));
    expect(black.rules.first, other);
    expect(sideKept(black, 'Kasparov, Gary'), Side.black);
    expect(keepingSide(black, 'Kasparov, Gary', null).rules, [other]);
  });
}

const _kasparov = '''
[Event "Wch U16"]
[White "Chandler, Murray G"]
[Black "Kasparov, Gary"]
[Result "1-0"]

1. e4 c5 1-0

[Event "Wch U16"]
[White "Kasparov, Gary"]
[Black "Galle, Andre"]
[Result "1-0"]

1. d4 d5 1-0

[Event "Wch U16"]
[White "Kasparov, Gary"]
[Black "Grinberg, Nir"]
[Result "1/2-1/2"]

1. d4 Nf6 1/2-1/2
''';

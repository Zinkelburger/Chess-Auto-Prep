// The row over the window, on its own: the list toggle, Back and Forward,
// the mode menu, the Actions menu and what is running.
import 'package:chess_auto_prep/app/mode.dart';
import 'package:chess_auto_prep/app/top_bar.dart';
import 'package:chess_auto_prep/ui/app_action.dart';
import 'package:chess_auto_prep/ui/app_icons.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<AppAction> actions;
  late int asked;
  late List<String> did;
  late ValueNotifier<int> changes;
  setUp(() {
    actions = [];
    asked = 0;
    did = [];
    changes = ValueNotifier(0);
  });
  tearDown(() => changes.dispose());

  Future<void> bar(
    WidgetTester tester, {
    bool listShown = true,
    String? backTo,
    String? forwardTo,
    String? activity,
    Listenable? heard,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: TopBar(
            mode: Mode.pgnViewer,
            onMode: (mode) => did.add(mode.name),
            backTo: backTo,
            forwardTo: forwardTo,
            onBack: () => did.add('back'),
            onForward: () => did.add('forward'),
            offered: (_) => true,
            onSettings: () {},
            listShown: listShown,
            onToggleList: () {},
            actions: () {
              asked++;
              return actions;
            },
            actionsChange: heard ?? changes,
            activity: activity,
            onActivity: () => did.add('activity'),
          ),
        ),
      ),
    );
  }

  VoidCallback? press(WidgetTester tester, String tooltip) => tester
      .widget<IconButton>(
        find.ancestor(
          of: find.byTooltip(tooltip),
          matching: find.byType(IconButton),
        ),
      )
      .onPressed;

  testWidgets('the list toggle is in the bar only while the list is hidden', (
    tester,
  ) async {
    await bar(tester);
    expect(find.byTooltip('Show the list'), findsNothing);
    await bar(tester, listShown: false);
    expect(find.byTooltip('Show the list'), findsOneWidget);
  });

  testWidgets('Back and Forward say where they go, and are off with nowhere '
      'to go', (tester) async {
    await bar(tester);
    expect(press(tester, 'Back (Alt+←)'), isNull);
    expect(press(tester, 'Forward (Alt+→)'), isNull);
    await bar(tester, backTo: 'Main', forwardTo: 'Sidelines');
    await tester.tap(find.byTooltip('Back to Main (Alt+←)'));
    await tester.tap(find.byTooltip('Forward to Sidelines (Alt+→)'));
    expect(did, ['back', 'forward']);
  });

  testWidgets('what is running is a button to it, and absent when nothing '
      'is', (tester) async {
    await bar(tester);
    expect(find.textContaining('running'), findsNothing);
    await bar(tester, activity: 'Search');
    await tester.tap(find.text('Search · running'));
    expect(did, ['activity']);
  });

  testWidgets('the mode menu ticks the mode on, and lines every name up', (
    tester,
  ) async {
    await bar(tester);
    await tester.tap(find.text(Mode.pgnViewer.label));
    await tester.pumpAndSettle();
    final ticked = find.ancestor(
      of: find.byIcon(AppIcons.tick),
      matching: find.byType(MenuItemButton),
    );
    expect(
      find.descendant(of: ticked, matching: find.text(Mode.pgnViewer.label)),
      findsOneWidget,
    );
    expect(find.byIcon(AppIcons.tick), findsOneWidget);
    expect(
      tester.getTopLeft(find.text(Mode.study.label)).dx,
      tester
          .getTopLeft(
            find.descendant(
              of: ticked,
              matching: find.text(Mode.pgnViewer.label),
            ),
          )
          .dx,
    );
  });

  group('the Actions menu', () {
    Future<void> open(WidgetTester tester) async {
      await tester.tap(find.text('Actions'));
      await tester.pumpAndSettle();
    }

    double top(WidgetTester tester, Finder finder) =>
        tester.getTopLeft(finder).dy;

    testWidgets('is not asked what it offers until it opens', (tester) async {
      actions = [AppAction('Flip board', () {})];
      await bar(tester);
      changes.value++;
      await tester.pump();
      expect(asked, 0);
      await open(tester);
      expect(find.text('Flip board'), findsOneWidget);
    });

    testWidgets('sections its work under headings, a rule between them, and '
        'puts the secondary controls in submenus after a rule', (tester) async {
      actions = [
        AppAction('Flip board', () {}),
        AppAction('Copy FEN', () {}, group: 'Copy'),
        AppAction('Add comment', () {}, group: 'Moves'),
        AppAction('Reset layout', () {}, group: 'View'),
      ];
      await bar(tester);
      await open(tester);
      expect(find.widgetWithText(SubmenuButton, 'Copy'), findsOneWidget);
      expect(find.widgetWithText(SubmenuButton, 'View'), findsOneWidget);
      expect(find.text('Copy FEN'), findsNothing);
      final rules = find.byType(Divider);
      expect(rules, findsNWidgets(2));
      expect(
        top(tester, find.text('Actions').last),
        lessThan(top(tester, rules.first)),
      );
      expect(
        top(tester, rules.first),
        lessThan(top(tester, find.text('Moves'))),
      );
      expect(
        top(tester, rules.last),
        lessThan(top(tester, find.widgetWithText(SubmenuButton, 'Copy'))),
      );
    });

    testWidgets('with only one kind of entry, has no rule', (tester) async {
      actions = [AppAction('Flip board', () {})];
      await bar(tester);
      await open(tester);
      expect(find.byType(Divider), findsNothing);
      await tester.tapAt(const Offset(1100, 700));
      await tester.pumpAndSettle();
      actions = [AppAction('Copy FEN', () {}, group: 'Copy')];
      await open(tester);
      expect(find.byType(Divider), findsNothing);
    });

    testWidgets('keeps up while open, even when what it hears is replaced', (
      tester,
    ) async {
      actions = [AppAction('Flip board', () {})];
      await bar(tester);
      await open(tester);
      actions = [AppAction('Save', () {})];
      changes.value++;
      await tester.pump();
      expect(find.text('Save'), findsOneWidget);
      final other = ValueNotifier(0);
      addTearDown(other.dispose);
      await bar(tester, heard: other);
      actions = [AppAction('Undo', () {})];
      other.value++;
      await tester.pump();
      expect(find.text('Undo'), findsOneWidget);
    });
  });
}

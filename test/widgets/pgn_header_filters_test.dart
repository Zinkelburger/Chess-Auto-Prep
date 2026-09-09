import 'package:chess_auto_prep/core/slice_filter_controller.dart';
import 'package:chess_auto_prep/models/pgn_filter_models.dart';
import 'package:chess_auto_prep/services/pgn_parsing_service.dart'
    show playerFieldMatches;
import 'package:chess_auto_prep/widgets/slice/header_filters.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _games = <GameRecord>[
  (
    headers: {
      'White': 'Carlsen, Magnus',
      'Black': 'Alpha',
      'Event': 'Open [A]',
      'Date': '2026.01.01',
      'ECO': 'B90',
    },
    pgnText: '*',
  ),
  (
    headers: {
      'White': 'Beta',
      'Black': 'Carlsen, Magnus',
      'Event': 'Open [A]',
      'Date': '2025.12.31',
      'ECO': 'B90',
    },
    pgnText: '*',
  ),
  (
    headers: {
      'White': 'Carlsen,M',
      'Black': 'Gamma',
      'Event': 'Open A',
      'ECO': 'B91',
    },
    pgnText: '*',
  ),
];

Future<void> _show(
  WidgetTester tester,
  SliceFilterController controller, {
  double width = 620,
  bool simple = false,
  List<GameRecord>? games = _games,
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: SingleChildScrollView(
              child: HeaderFilters(
                controller: controller,
                games: games,
                simple: simple,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

SliceFilterController _controller({
  String field = 'Event',
  MatchMode mode = MatchMode.contains,
  String value = 'Open',
}) => SliceFilterController(
  initialConfig: SliceConfig(
    headerFilters: [HeaderFilterConfig(field: field, mode: mode, value: value)],
  ),
);

Finder _input(String hint) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.hintText == hint,
);
Finder get _field => _input('Choose field');
Finder get _rule => _input('Choose rule');
Finder _value(SliceFilterController controller, [int index = 0]) =>
    find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.controller == controller.headerRows[index].controller,
    );

Future<void> _choose(
  WidgetTester tester,
  Finder input,
  String query,
  String label,
) async {
  await tester.enterText(input, query);
  await tester.pumpAndSettle();
  await tester.tap(
    find.descendant(
      of: find.byType(CompositedTransformFollower),
      matching: find.text(label),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _close(
  WidgetTester tester,
  SliceFilterController controller,
) async {
  await tester.pumpWidget(const SizedBox());
  controller.dispose();
}

void main() {
  for (final simple in [false, true]) {
    testWidgets('Field / Rule / Value table at 620px (simple: $simple)', (
      tester,
    ) async {
      final controller = _controller();
      await _show(tester, controller, simple: simple);
      expect(find.text('Field'), findsOneWidget);
      expect(find.text('Rule'), findsOneWidget);
      expect(find.text('Value'), findsOneWidget);
      final fieldRect = tester.getRect(_field);
      final ruleRect = tester.getRect(_rule);
      final valueRect = tester.getRect(_value(controller));
      expect(fieldRect.top, ruleRect.top);
      expect(ruleRect.top, valueRect.top);
      expect(fieldRect.right, lessThan(ruleRect.left));
      expect(ruleRect.right, lessThan(valueRect.left));
      expect(tester.takeException(), isNull);
      await _close(tester, controller);
    });
  }

  testWidgets('narrow rows stack labelled editable controls without overflow', (
    tester,
  ) async {
    final controller = _controller();
    await _show(tester, controller, width: 300, simple: true);
    expect(
      tester.getRect(_rule).top,
      greaterThan(tester.getRect(_field).bottom),
    );
    expect(
      tester.getRect(_value(controller)).top,
      greaterThan(tester.getRect(_rule).bottom),
    );
    for (final label in ['Field', 'Rule', 'Value']) {
      expect(find.text(label), findsOneWidget);
    }
    await tester.enterText(_value(controller), 'custom event');
    await tester.pumpAndSettle();
    expect(controller.headerConfigs.single.value, 'custom event');
    expect(tester.takeException(), isNull);
    await _close(tester, controller);
  });

  testWidgets('large text switches a 620px pane to stacked controls', (
    tester,
  ) async {
    final controller = _controller();
    await _show(tester, controller, textScale: 1.5);
    expect(
      tester.getRect(_rule).top,
      greaterThan(tester.getRect(_field).bottom),
    );
    expect(tester.takeException(), isNull);
    await _close(tester, controller);
  });

  testWidgets(
    'literal case-insensitive suggestions have counts and select Exact',
    (tester) async {
      final controller = _controller();
      await _show(tester, controller);
      await tester.enterText(_value(controller), 'oPeN [');
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, 'Open [A]'), findsOneWidget);
      expect(find.text('2 games'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'Open A'), findsNothing);
      expect(controller.headerConfigs.single.mode, MatchMode.contains);
      await tester.tap(find.widgetWithText(ListTile, 'Open [A]'));
      await tester.pumpAndSettle();
      expect(controller.headerConfigs.single.value, 'Open [A]');
      expect(controller.headerConfigs.single.mode, MatchMode.exact);
      expect(
        tester.widget<TextField>(_value(controller)).controller!.text,
        'Open [A]',
      );
      expect(tester.widget<TextField>(_rule).controller!.text, 'Exact');
      expect(find.byType(ListTile), findsNothing);

      await _choose(tester, _rule, 'contains', 'Contains');
      await tester.enterText(_value(controller), 'opne');
      await tester.pumpAndSettle();
      expect(find.byType(ListTile), findsNothing, reason: 'No fuzzy matching');
      expect(controller.headerConfigs.single.value, 'opne');
      expect(controller.headerConfigs.single.mode, MatchMode.contains);
      await _close(tester, controller);
    },
  );

  testWidgets(
    'Player suggestions use both colours and preserve exact spelling',
    (tester) async {
      final controller = _controller(
        field: kPlayerHeaderField,
        value: 'Carlsen',
      );
      await _show(tester, controller);
      await tester.enterText(_value(controller), 'cArLsEn');
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, 'Carlsen, Magnus'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'Carlsen,M'), findsOneWidget);
      expect(find.text('2 games'), findsOneWidget);
      expect(find.text('1 game'), findsOneWidget);
      await tester.tap(find.widgetWithText(ListTile, 'Carlsen, Magnus'));
      await tester.pumpAndSettle();
      final filter = controller.headerConfigs.single;
      expect(filter.field, kPlayerHeaderField);
      expect(filter.mode, MatchMode.exact);
      expect(filter.value, 'Carlsen, Magnus');
      expect(tester.widget<TextField>(_rule).controller!.text, 'Exact');
      expect(
        _games.where(
          (game) => playerFieldMatches(
            game.headers['White']!,
            game.headers['Black']!,
            filter.value,
            filter.mode,
          ),
        ),
        hasLength(2),
      );
      await _close(tester, controller);
    },
  );

  testWidgets('suggestions follow the selected field and replaced game list', (
    tester,
  ) async {
    final controller = _controller(field: kPlayerHeaderField, value: 'Carlsen');
    await _show(tester, controller);
    await _choose(tester, _field, 'Black', 'Black');
    await tester.enterText(_value(controller), 'carlsen');
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'Carlsen, Magnus'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Carlsen,M'), findsNothing);
    expect(find.text('1 game'), findsOneWidget);
    await _show(
      tester,
      controller,
      games: const [
        (headers: {'Black': 'Carlsen, New'}, pgnText: '*'),
      ],
    );
    await tester.enterText(_value(controller), 'CARLSEN');
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'Carlsen, New'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Carlsen, Magnus'), findsNothing);
    expect(tester.takeException(), isNull);
    await _close(tester, controller);
  });

  testWidgets('preset rows allow field, rule, value edits and removal', (
    tester,
  ) async {
    final controller = _controller(field: 'White', value: 'Carlsen, Magnus');
    controller.togglePresetHeaderFilter('Black', 'Alpha');
    await _show(tester, controller, simple: true);
    expect(_field, findsNWidgets(2));
    expect(_rule, findsNWidgets(2));
    await _choose(tester, _field.last, 'Event', 'Event');
    await _choose(tester, _rule.last, 'exact', 'Exact');
    await tester.enterText(_value(controller, 1), 'Custom event');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Remove filter').first);
    await tester.pumpAndSettle();
    expect(controller.headerConfigs.single.toJson(), {
      'field': 'Event',
      'mode': 'exact',
      'value': 'Custom event',
    });
    await tester.enterText(_value(controller), 'Updated event');
    await tester.pumpAndSettle();
    expect(controller.headerConfigs.single.value, 'Updated event');
    expect(tester.takeException(), isNull);
    await _close(tester, controller);
  });

  testWidgets('new row takes field focus and preserves existing values', (
    tester,
  ) async {
    final controller = _controller(field: 'Date', value: '1960');
    await _show(tester, controller);
    await tester.tap(find.text('Filter'));
    await tester.pumpAndSettle();
    expect(_field, findsNWidgets(2));
    expect(tester.widget<TextField>(_field.last).focusNode!.hasFocus, isTrue);
    await tester.enterText(_value(controller, 1), 'Carlsen; Magnus');
    await tester.pumpAndSettle();
    expect(find.textContaining('Carlsen, Magnus ×2'), findsOneWidget);
    expect(controller.headerConfigs.first.value, '1960');
    expect(controller.headerConfigs.last.value, 'Carlsen; Magnus');
    expect(tester.takeException(), isNull);
    await _close(tester, controller);
  });

  testWidgets('numeric bounds, ECO warnings, and inline regex errors', (
    tester,
  ) async {
    final controller = _controller();
    await _show(tester, controller);
    await _choose(tester, _field, 'WhiteElo', 'White rating');
    expect(tester.widget<TextField>(_rule).controller!.text, 'At least');
    await tester.enterText(_value(controller), '2200');
    await tester.pumpAndSettle();
    expect(controller.headerConfigs.single.mode, MatchMode.after);
    await _choose(tester, _field, 'Date', 'Date / year');
    await _choose(tester, _rule, 'before', 'In or before');
    await tester.enterText(_value(controller), '1960');
    await tester.pumpAndSettle();
    expect(controller.headerConfigs.single.chipLabel, 'In or before 1960');
    await _choose(tester, _field, 'ECO', 'ECO');
    await _choose(tester, _rule, 'exact', 'Exact');
    await tester.enterText(_value(controller), 'B');
    await tester.pumpAndSettle();
    expect(find.text('Expected A00–E99'), findsOneWidget);
    await tester.enterText(_value(controller), 'B90');
    await tester.pumpAndSettle();
    expect(find.text('Expected A00–E99'), findsNothing);
    await _choose(tester, _rule, 'regex', 'Matches regex');
    await tester.enterText(_value(controller), '[');
    await tester.pumpAndSettle();
    expect(find.text('Invalid regular expression'), findsOneWidget);
    expect(controller.headerConfigs.single.value, '[');
    await tester.enterText(_value(controller), '^B[0-9]{2}\$');
    await tester.pumpAndSettle();
    expect(find.text('Invalid regular expression'), findsNothing);
    await tester.enterText(_value(controller), '[');
    await tester.pumpAndSettle();
    await _choose(tester, _rule, 'contains', 'Contains');
    expect(find.text('Invalid regular expression'), findsNothing);
    expect(tester.takeException(), isNull);
    await _close(tester, controller);
  });

  testWidgets('keyboard navigation selects and Escape preserves typed text', (
    tester,
  ) async {
    final controller = _controller(value: 'Open');
    await _show(tester, controller);
    await tester.enterText(_value(controller), 'open');
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsNothing);
    expect(controller.headerConfigs.single.value, 'open');
    expect(controller.headerConfigs.single.mode, MatchMode.contains);
    await tester.enterText(_value(controller), 'Open');
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(controller.headerConfigs.single.value, 'Open A');
    expect(controller.headerConfigs.single.mode, MatchMode.exact);
    expect(tester.widget<TextField>(_rule).controller!.text, 'Exact');
    expect(tester.takeException(), isNull);
    await _close(tester, controller);
  });

  testWidgets('free text works without games and focused rows can be reset', (
    tester,
  ) async {
    final controller = _controller();
    await _show(tester, controller, games: null);
    await tester.enterText(_value(controller), 'Unlisted event');
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsNothing);
    expect(controller.headerConfigs.single.value, 'Unlisted event');
    controller.reset();
    await tester.pumpAndSettle();
    expect(controller.headerConfigs, isEmpty);
    expect(tester.takeException(), isNull);
    await _close(tester, controller);
  });
}

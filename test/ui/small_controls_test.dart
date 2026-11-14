// The small shared controls on their own: what a list says in place of its
// rows, a problem line, a tick row, segments, an icon button.
import 'package:chess_auto_prep/ui/check_row.dart';
import 'package:chess_auto_prep/ui/list_message.dart';
import 'package:chess_auto_prep/ui/problem_line.dart';
import 'package:chess_auto_prep/ui/segments.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:chess_auto_prep/ui/tool_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _show(WidgetTester tester, Widget child) => tester.pumpWidget(
  MaterialApp(
    theme: darkTheme(),
    home: Scaffold(body: Center(child: child)),
  ),
);

void main() {
  testWidgets('a list being read says so out loud; an empty one does not', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _show(
      tester,
      const Column(
        children: [
          ListMessage.loading('Reading puzzles…'),
          ListMessage('No puzzles yet.'),
        ],
      ),
    );
    expect(
      tester.getSemantics(find.text('Reading puzzles…')),
      matchesSemantics(label: 'Reading puzzles…', isLiveRegion: true),
    );
    expect(
      tester.getSemantics(find.text('No puzzles yet.')),
      matchesSemantics(label: 'No puzzles yet.'),
    );
    semantics.dispose();
  });

  testWidgets('a problem is read out when it comes', (tester) async {
    final semantics = tester.ensureSemantics();
    await _show(tester, const ProblemLine('Disk full'));
    expect(
      tester.getSemantics(find.text('Disk full')),
      matchesSemantics(
        label: 'Disk full',
        tooltip: 'Disk full',
        isLiveRegion: true,
      ),
    );
    semantics.dispose();
  });

  group('a tick row', () {
    testWidgets('a click anywhere on it turns it the other way', (
      tester,
    ) async {
      final changes = <bool>[];
      for (final value in [false, true]) {
        await _show(
          tester,
          CheckRow(label: 'Coordinates', value: value, onChanged: changes.add),
        );
        await tester.tap(find.text('Coordinates'));
      }
      expect(changes, [true, false]);
    });

    testWidgets('the box turns it the other way too', (tester) async {
      final changes = <bool>[];
      await _show(
        tester,
        CheckRow(label: 'Coordinates', value: true, onChanged: changes.add),
      );
      await tester.tap(find.byType(Checkbox));
      expect(changes, [false]);
    });

    testWidgets('without a callback, it cannot change', (tester) async {
      await _show(
        tester,
        const CheckRow(label: 'Coordinates', value: true, onChanged: null),
      );
      expect(tester.widget<Checkbox>(find.byType(Checkbox)).onChanged, isNull);
      expect(tester.widget<InkWell>(find.byType(InkWell).first).onTap, isNull);
    });
  });

  group('segments', () {
    Widget segments({
      String? selected,
      bool emptyAllowed = false,
      bool narrow = false,
      ValueChanged<String>? onChanged,
    }) => Segments<String>(
      segments: const [
        ButtonSegment(value: 'read', label: Text('Read')),
        ButtonSegment(value: 'edit', label: Text('Edit')),
      ],
      selected: selected,
      onChanged: onChanged ?? (_) {},
      emptyAllowed: emptyAllowed,
      narrow: narrow,
    );

    double width(WidgetTester tester) =>
        tester.getSize(find.byType(SegmentedButton<String>)).width;

    testWidgets('one is chosen, and a pick says which', (tester) async {
      final picked = <String>[];
      await _show(tester, segments(selected: 'read', onChanged: picked.add));
      final button = tester.widget<SegmentedButton<String>>(
        find.byType(SegmentedButton<String>),
      );
      expect(button.selected, {'read'});
      expect(button.emptySelectionAllowed, isFalse);
      await tester.tap(find.text('Edit'));
      expect(picked, ['edit']);
    });

    testWidgets('picking the chosen one again, where none may be chosen, '
        'calls nothing', (tester) async {
      final picked = <String>[];
      await _show(
        tester,
        segments(selected: 'read', emptyAllowed: true, onChanged: picked.add),
      );
      await tester.tap(find.text('Read'));
      expect(picked, isEmpty);
    });

    testWidgets('the chosen one grows no tick', (tester) async {
      await _show(tester, segments(emptyAllowed: true));
      final none = width(tester);
      await _show(tester, segments(selected: 'read'));
      expect(width(tester), none);
    });

    testWidgets('narrow ones are tighter than the usual', (tester) async {
      await _show(tester, segments(selected: 'read'));
      final usual = width(tester);
      await _show(tester, segments(selected: 'read', narrow: true));
      expect(width(tester), lessThan(usual));
    });
  });

  group('a tool button', () {
    testWidgets('on, it shows its filled symbol', (tester) async {
      await _show(
        tester,
        ToolButton(
          icon: Icons.star_border,
          selectedIcon: Icons.star,
          tooltip: 'Favourite',
          selected: true,
          onPressed: () {},
        ),
      );
      expect(find.byIcon(Icons.star), findsOneWidget);
      expect(find.byIcon(Icons.star_border), findsNothing);
    });

    testWidgets('without a filled symbol, it shows its own when on', (
      tester,
    ) async {
      await _show(
        tester,
        ToolButton(
          icon: Icons.star_border,
          tooltip: 'Favourite',
          selected: true,
          onPressed: () {},
        ),
      );
      expect(find.byIcon(Icons.star_border), findsOneWidget);
    });
  });
}

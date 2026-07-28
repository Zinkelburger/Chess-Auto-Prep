import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/features/repertoire/widgets/repertoire_lines_side_panel.dart';

Widget _wrap(Widget child) => MaterialApp(
  home: Scaffold(
    body: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Expanded(child: SizedBox()),
        child,
      ],
    ),
  ),
);

class _Host extends StatefulWidget {
  const _Host({
    required this.collapsed,
    required this.surface,
    this.lineCount = 3,
  });

  final bool collapsed;
  final RepertoireLinesSurface surface;
  final int lineCount;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);
  late bool _collapsed = widget.collapsed;

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepertoireLinesSidePanel(
      collapsed: _collapsed,
      width: 300,
      surface: widget.surface,
      lineCount: widget.lineCount,
      tabController: _tabs,
      tabs: const [
        Tab(text: 'Lines'),
        Tab(text: 'Tree'),
      ],
      children: const [Text('lines body'), Text('tree body')],
      onCollapsedChanged: (v) => setState(() => _collapsed = v),
    );
  }
}

void main() {
  group('expanded', () {
    testWidgets('shows both tabs and the first body', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const _Host(collapsed: false, surface: RepertoireLinesSurface.lines),
        ),
      );

      expect(find.text('Lines'), findsOneWidget);
      expect(find.text('Tree'), findsOneWidget);
      expect(find.text('lines body'), findsOneWidget);
      expect(find.byTooltip('Hide lines (L)'), findsOneWidget);
    });

    testWidgets('the hide button collapses it', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const _Host(collapsed: false, surface: RepertoireLinesSurface.lines),
        ),
      );

      await tester.tap(find.byTooltip('Hide lines (L)'));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Show lines (L)'), findsOneWidget);
      expect(find.text('lines body'), findsNothing);
    });
  });

  group('collapsed strip', () {
    testWidgets('names the surface so a running session stays visible', (
      tester,
    ) async {
      for (final (surface, label) in [
        (RepertoireLinesSurface.lines, 'Lines (3)'),
        (RepertoireLinesSurface.draft, 'Draft'),
        (RepertoireLinesSurface.session, 'Session'),
      ]) {
        await tester.pumpWidget(
          _wrap(_Host(collapsed: true, surface: surface, lineCount: 3)),
        );
        await tester.pumpAndSettle();
        expect(find.text(label), findsOneWidget, reason: 'for $surface');
      }
    });

    testWidgets('tapping the strip expands it again', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const _Host(collapsed: true, surface: RepertoireLinesSurface.lines),
        ),
      );

      await tester.tap(find.byType(InkWell));
      await tester.pumpAndSettle();

      expect(find.text('lines body'), findsOneWidget);
    });
  });

  group('drag handle', () {
    testWidgets('widens the panel as the pointer moves left', (tester) async {
      final widths = <double>[];
      var ended = 0;
      await tester.pumpWidget(
        _wrap(
          SizedBox(
            width: 300,
            child: Row(
              children: [
                RepertoireLinesPanelDragHandle(
                  currentWidth: 293,
                  minWidth: 220,
                  maxWidth: 600,
                  onWidthChanged: widths.add,
                  onDragEnd: () => ended++,
                ),
                const Expanded(child: SizedBox()),
              ],
            ),
          ),
        ),
      );

      await tester.drag(
        find.byType(RepertoireLinesPanelDragHandle),
        const Offset(-80, 0),
      );
      await tester.pumpAndSettle();

      expect(widths, isNotEmpty);
      expect(widths.last, greaterThan(293));
      expect(ended, 1);
    });

    testWidgets('never reports a width outside the allowed range', (
      tester,
    ) async {
      final widths = <double>[];
      await tester.pumpWidget(
        _wrap(
          SizedBox(
            width: 300,
            child: Row(
              children: [
                RepertoireLinesPanelDragHandle(
                  currentWidth: 293,
                  minWidth: 220,
                  maxWidth: 320,
                  onWidthChanged: widths.add,
                  onDragEnd: () {},
                ),
                const Expanded(child: SizedBox()),
              ],
            ),
          ),
        ),
      );

      await tester.drag(
        find.byType(RepertoireLinesPanelDragHandle),
        const Offset(-900, 0),
      );
      await tester.drag(
        find.byType(RepertoireLinesPanelDragHandle),
        const Offset(900, 0),
      );
      await tester.pumpAndSettle();

      expect(widths, isNotEmpty);
      expect(widths.every((w) => w >= 220 && w <= 320), isTrue);
    });
  });
}

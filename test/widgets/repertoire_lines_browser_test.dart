import 'package:chess_auto_prep/design_system/theme/app_theme.dart';
import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'package:chess_auto_prep/models/repertoire_line.dart';
import 'package:chess_auto_prep/widgets/lines/line_item_row.dart';
import 'package:chess_auto_prep/widgets/repertoire_lines_browser.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

RepertoireLine _line(String name, List<String> moves) => RepertoireLine(
  id: name,
  name: name,
  moves: moves,
  color: 'white',
  startPosition: Chess.initial,
  fullPgn: '[Event "$name"]\n\n*',
);

Widget _host(Widget child) => MaterialApp(
  theme: AppTheme.dark(),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

List<String> _visibleIds(WidgetTester tester) => tester
    .widgetList<LineItemRow>(find.byType(LineItemRow))
    .map((row) => row.line.id)
    .toList();

void main() {
  late List<RepertoireLine> lines;
  setUp(() {
    lines = [
      _line('Beta', ['d4', 'd5']),
      _line('Alpha', ['e4', 'e5', 'Nf3', 'Nc6']),
    ];
  });

  testWidgets('table headers sort actual rows and selection keeps its line', (
    tester,
  ) async {
    RepertoireLine? selected;
    await tester.pumpWidget(
      _host(
        RepertoireLinesBrowser(
          lines: lines,
          onLineSelected: (line) => selected = line,
        ),
      ),
    );
    expect(_visibleIds(tester), ['Alpha', 'Beta']);
    await tester.tap(find.text('Line'));
    await tester.pump();
    expect(_visibleIds(tester), ['Beta', 'Alpha']);
    await tester.tap(find.text('Moves'));
    await tester.pump();
    expect(_visibleIds(tester), ['Beta', 'Alpha']);
    await tester.tap(find.text('Moves'));
    await tester.pump();
    expect(_visibleIds(tester), ['Alpha', 'Beta']);
    await tester.tap(find.text('Beta'));
    expect(selected, same(lines.first));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'search reset restores rows without replacing their scroll owner',
    (tester) async {
      await tester.pumpWidget(_host(RepertoireLinesBrowser(lines: lines)));
      final scroll = tester.widget<ListView>(find.byType(ListView)).controller;
      await tester.enterText(find.byType(TextField), 'missing');
      await tester.pump(const Duration(milliseconds: 301));
      expect(find.byType(LineItemRow), findsNothing);
      expect(find.text('No lines match the current filters'), findsOneWidget);
      await tester.tap(find.text('Show all lines'));
      await tester.pump();
      expect(_visibleIds(tester), ['Alpha', 'Beta']);
      expect(
        tester.widget<ListView>(find.byType(ListView)).controller,
        same(scroll),
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'retained list delegate keeps its original count and line snapshot',
    (tester) async {
      final originalSelections = <RepertoireLine>[];
      final replacementSelections = <RepertoireLine>[];
      await tester.pumpWidget(
        _host(
          RepertoireLinesBrowser(
            lines: lines,
            onLineSelected: originalSelections.add,
          ),
        ),
      );
      final delegate =
          tester.widget<ListView>(find.byType(ListView)).childrenDelegate
              as SliverChildBuilderDelegate;
      expect(delegate.childCount, 2);
      await tester.enterText(find.byType(TextField), 'Alpha');
      await tester.pump(const Duration(milliseconds: 301));
      expect(_visibleIds(tester), ['Alpha']);
      await tester.pumpWidget(
        _host(
          RepertoireLinesBrowser(
            lines: [
              _line('Gamma', ['c4']),
            ],
            onLineSelected: replacementSelections.add,
          ),
        ),
      );
      final oldRow =
          delegate.builder(
                tester.element(find.byType(RepertoireLinesBrowser)),
                1,
              )
              as LineItemRow;
      expect(oldRow.line, same(lines.first));
      expect(oldRow.displayTitle, 'Beta');
      oldRow.onLineSelected!(oldRow.line);
      expect(originalSelections, [same(lines.first)]);
      expect(replacementSelections, isEmpty);
      expect(delegate.childCount, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'coverage prompt takes priority over empty rows and resets filters',
    (tester) async {
      var runs = 0;
      Widget browser({bool running = false}) => _host(
        RepertoireLinesBrowser(
          lines: const [],
          isCoverageRunning: running,
          onCoveragePressed: () => runs++,
        ),
      );
      await tester.pumpWidget(browser());
      await tester.tap(find.text('Covered'));
      await tester.pump();
      expect(find.text('Run coverage analysis'), findsOneWidget);
      expect(find.text('No lines match the current filters'), findsNothing);
      await tester.tap(find.text('Run coverage analysis'));
      expect(runs, 1);
      await tester.pumpWidget(browser(running: true));
      expect(find.text('Run coverage analysis'), findsNothing);
      await tester.tap(find.text('Show all lines'));
      await tester.pump();
      expect(find.text('No lines in repertoire'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('row deletion confirms the selected line and Cancel keeps it', (
    tester,
  ) async {
    final deleted = <RepertoireLine>[];
    await tester.pumpWidget(
      _host(RepertoireLinesBrowser(lines: lines, onLineDeleted: deleted.add)),
    );
    final beta = find.ancestor(
      of: find.text('Beta'),
      matching: find.byType(LineItemRow),
    );
    final delete = find.descendant(
      of: beta,
      matching: find.byTooltip('Delete line'),
    );
    await tester.tap(delete);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(deleted, isEmpty);
    await tester.tap(delete);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(deleted, [same(lines.first)]);
    expect(tester.takeException(), isNull);
  });
}

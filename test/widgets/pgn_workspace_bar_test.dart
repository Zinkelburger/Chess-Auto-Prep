import 'package:chess_auto_prep/core/pgn/pgn_workspace.dart';
import 'package:chess_auto_prep/widgets/pgn/pgn_workspace_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('new tabs scroll their close button into view', (tester) async {
    final workspace = PgnWorkspace();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: ListenableBuilder(
              listenable: workspace,
              builder: (_, _) => PgnWorkspaceBar(
                workspace: workspace,
                onSelect: (id) => workspace.index = id,
                onClose: workspace.close,
                addButton: const Icon(Icons.add),
              ),
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 5; i++) {
      workspace.index = workspace.add('Reference database $i');
    }
    await tester.pumpAndSettle();
    final close = find.byTooltip('Close Reference database 4 tab');
    expect(tester.getRect(close).right, lessThanOrEqualTo(320));
    await tester.tap(close);
    await tester.pumpAndSettle();
    expect(workspace.openTabs.length, 5);
    expect(tester.takeException(), isNull);
  });
  testWidgets('tabs appear on demand, switch and close back to a lone game', (
    tester,
  ) async {
    final workspace = PgnWorkspace();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: workspace,
            builder: (_, _) => PgnWorkspaceBar(
              workspace: workspace,
              onSelect: (id) => workspace.index = id,
              onClose: workspace.close,
              addButton: const Icon(Icons.add),
            ),
          ),
        ),
      ),
    );
    expect(find.text('Game'), findsNothing);
    workspace.index = PgnWorkspace.analysis;
    await tester.pump();
    expect(find.text('Game'), findsOneWidget);
    expect(find.byTooltip('Close Game tab'), findsNothing);
    await tester.tap(find.text('Game'));
    expect(workspace.index, 0);
    await tester.tap(find.byTooltip('Close Analysis tab'));
    await tester.pump();
    expect(find.text('Game'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

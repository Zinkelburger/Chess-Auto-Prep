import 'package:chess_auto_prep/core/pgn/pgn_workspace.dart';
import 'package:chess_auto_prep/widgets/pgn/pgn_workspace_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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

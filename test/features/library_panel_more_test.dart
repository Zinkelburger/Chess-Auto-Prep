// The builder's repertoire list: one button for a new repertoire, the one
// the empty list shows or the toolbar's once there is a list; and Deleted
// chapters a way out of the list and back into it.
import 'package:chess_auto_prep/features/library/library_panel.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/library_fixture.dart';
import '../support/scripted_files.dart';
import '../support/status_host.dart';

void main() {
  late LibraryFixture fixture;
  tearDown(() => fixture.dispose());

  Future<void> show(WidgetTester tester, List<RepertoireFolder> folders) async {
    fixture = await openLibrary(folders);
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: StatusHost(
            child: LibraryPanel(
              library: fixture.library,
              selected: null,
              onOpen: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the toolbar offers a new repertoire only beside a list', (
    tester,
  ) async {
    await show(tester, []);
    expect(find.byTooltip('New repertoire…'), findsNothing);
    fixture.dispose();
    await show(tester, [
      folder('benko', ['Main']),
    ]);
    expect(find.byTooltip('New repertoire…'), findsOneWidget);
  });

  testWidgets('Deleted chapters has a way back to the list', (tester) async {
    await show(tester, [
      folder('benko', ['Main']),
    ]);
    await tester.tap(find.text('Deleted chapters'));
    await tester.pumpAndSettle();
    expect(find.text('benko'), findsNothing);
    await tester.tap(find.byTooltip('Back to repertoires'));
    await tester.pumpAndSettle();
    expect(find.text('benko'), findsOneWidget);
  });
}

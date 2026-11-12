import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:chess_auto_prep/workspace/reading/notes_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';
import '../support/session_fixture.dart';

/// The Notes tab: the move's note with the whole pane to write in.
void main() {
  late SessionFixture fixture;
  final sicilian = NodePath.of([0]);

  setUp(() async => fixture = await openSession(blackChapter));

  tearDown(() => fixture.dispose());

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: Column(
            children: [
              SizedBox(height: 400, child: NotesPane(session: fixture.session)),
              const TextField(key: Key('elsewhere')),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('the note of the move under the cursor fills the pane and '
      'names its move', (tester) async {
    fixture.session.cursor.goTo(sicilian);
    await pump(tester);
    expect(find.text('The Sicilian'), findsOneWidget);
    expect(find.text('Note on 1... c5'), findsOneWidget);
    final box = tester.getSize(find.byType(TextField).first);
    expect(box.height, greaterThan(300));
  });

  testWidgets('several lines written here are saved on the move', (
    tester,
  ) async {
    fixture.session.cursor.goTo(sicilian);
    await pump(tester);
    await tester.enterText(
      find.byType(TextField).first,
      'Plan\n\nPlay ...d6 and ...a6 before castling.',
    );
    await tester.tap(find.byKey(const Key('elsewhere')));
    await tester.pumpAndSettle();
    expect(fixture.onDisk, contains('Play ...d6 and ...a6 before castling.'));
  });

  testWidgets('at the start it is the note before the first move', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Note before the first move'), findsOneWidget);
  });

  testWidgets('nothing shows while part of the game is hidden', (tester) async {
    fixture.session.cursor.goTo(sicilian);
    fixture.session.showOnlyTo(const NodePath.root());
    await pump(tester);
    expect(find.byType(TextField), findsOneWidget, reason: 'only the other');
  });
}

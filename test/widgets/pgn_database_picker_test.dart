import 'package:chess_auto_prep/widgets/pgn/pgn_database_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('database tab searches recent files and opens the selected PGN', (
    tester,
  ) async {
    String? selected;
    var openedCollection = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 350,
            child: PgnDatabasePicker(
              recent: const ['/fixtures/masters.pgn', '/fixtures/my-books.pgn'],
              onSelected: (path) => selected = path,
              onCollection: () => openedCollection = true,
            ),
          ),
        ),
      ),
    );
    expect(find.byType(AlertDialog), findsNothing);
    await tester.enterText(find.byType(TextField), 'masters');
    await tester.pump();
    expect(find.text('my-books.pgn'), findsNothing);
    await tester.tap(find.text('masters.pgn'));
    expect(selected, '/fixtures/masters.pgn');
    await tester.tap(find.text('Organize or export this collection'));
    expect(openedCollection, isTrue);
    await tester.enterText(find.byType(TextField), 'missing');
    await tester.pump();
    expect(find.text('No recent files match'), findsOneWidget);
    expect(find.text('Open PGN database…'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

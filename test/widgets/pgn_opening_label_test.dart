import 'package:chess_auto_prep/services/opening_catalog.dart';
import 'package:chess_auto_prep/widgets/pgn/pgn_opening_label.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('code-only PGNs show an opening name without changing tags', (
    tester,
  ) async {
    await tester.runAsync(() => OpeningCatalog.load());
    final headers = {'ECO': 'E94'};
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PgnOpeningLabel(headers: headers)),
      ),
    );
    await tester.runAsync(() async {});
    await tester.pumpAndSettle();
    expect(
      tester.widget<SelectableText>(find.byType(SelectableText)).data,
      "King's Indian Defense: Orthodox Variation (ECO E94)",
    );
    expect(headers, {'ECO': 'E94'});
  });

  testWidgets(
    'supplied opening names are preserved and missing tags are quiet',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                PgnOpeningLabel(
                  headers: {'Opening': 'My opening', 'ECO': 'A00'},
                ),
                PgnOpeningLabel(headers: {'Opening': '?', 'ECO': '?'}),
              ],
            ),
          ),
        ),
      );
      expect(find.text('My opening (ECO A00)'), findsOneWidget);
      expect(find.byType(SelectableText), findsOneWidget);
    },
  );
}

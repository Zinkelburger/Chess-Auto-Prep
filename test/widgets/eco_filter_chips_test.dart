import 'package:chess_auto_prep/models/pgn_filter_models.dart';
import 'package:chess_auto_prep/services/opening_catalog.dart';
import 'package:chess_auto_prep/widgets/common/static_board_thumbnail.dart';
import 'package:chess_auto_prep/widgets/slice/eco_filter_chips.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'only canonical ECO sets become chips; arbitrary expressions stay editable',
    () {
      expect(selectedEcoCodes('B00', MatchMode.exact), ['B00']);
      expect(selectedEcoCodes(r'^(B00|D00)$', MatchMode.regex), ['B00', 'D00']);
      expect(selectedEcoCodes('B0', MatchMode.contains), isEmpty);
      expect(selectedEcoCodes(r'^B.*$', MatchMode.regex), isEmpty);
      expect(selectedEcoCodes('B00', MatchMode.notContains), isEmpty);
      expect(
        selectedEcoCodes(ecoCodeExpression(['B00', 'D00']), MatchMode.regex),
        ['B00', 'D00'],
      );
    },
  );
  testWidgets(
    'thumbnails default on and can be hidden; removing a code preserves others',
    (tester) async {
      List<String>? changed;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EcoFilterChips(
              codes: const ['B00', 'D00'],
              openings: Future.value(const [
                CatalogOpening(eco: 'B00', name: 'King pawn', moves: ['e4']),
                CatalogOpening(eco: 'D00', name: 'Queen pawn', moves: ['d4']),
              ]),
              onChanged: (codes) => changed = codes,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(StaticBoardThumbnail), findsNWidgets(2));
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      expect(find.byType(StaticBoardThumbnail), findsNothing);
      tester
          .widget<InputChip>(find.widgetWithText(InputChip, 'B00'))
          .onDeleted!();
      expect(changed, ['D00']);
    },
  );
}

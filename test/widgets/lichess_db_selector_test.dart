import 'package:chess_auto_prep/features/coverage/services/coverage_service.dart'
    show LichessDatabase;
import 'package:chess_auto_prep/widgets/lichess_db_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pump(
    WidgetTester tester, {
    LichessDatabase database = LichessDatabase.lichess,
    bool showTwic = false,
    bool classicalOnly = false,
    ValueChanged<bool>? onClassicalOnlyChanged,
    ValueChanged<LichessDatabase>? onDatabaseChanged,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: LichessDbSelector(
              compact: true,
              database: database,
              onDatabaseChanged: onDatabaseChanged ?? (_) {},
              selectedSpeeds: const {'blitz'},
              onSpeedsChanged: (_) {},
              selectedRatings: const {'2000'},
              onRatingsChanged: (_) {},
              showTwic: showTwic,
              classicalOnly: classicalOnly,
              onClassicalOnlyChanged: onClassicalOnlyChanged,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('TWIC is offered only when the caller has it', (tester) async {
    await pump(tester);
    expect(find.text('TWIC'), findsNothing);
    await pump(tester, showTwic: true);
    expect(find.text('TWIC'), findsOneWidget);
  });

  testWidgets('choosing TWIC reports it and shows its one filter', (
    tester,
  ) async {
    LichessDatabase? chosen;
    await pump(
      tester,
      showTwic: true,
      onDatabaseChanged: (db) => chosen = db,
      onClassicalOnlyChanged: (_) {},
    );
    await tester.tap(find.text('TWIC'));
    expect(chosen, LichessDatabase.twic);
    expect(find.text('Classical OTB only'), findsNothing);

    bool? toggled;
    await pump(
      tester,
      showTwic: true,
      database: LichessDatabase.twic,
      onClassicalOnlyChanged: (on) => toggled = on,
    );
    expect(find.text('Classical OTB only'), findsOneWidget);
    expect(find.text('Speeds:'), findsNothing);
    await tester.tap(find.text('Classical OTB only'));
    expect(toggled, isTrue);
  });
}

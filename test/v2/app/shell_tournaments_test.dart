import 'package:chess_auto_prep/v2/app/mode.dart';
import 'package:chess_auto_prep/v2/engines/engine_supervisor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/scripted_tournaments.dart';
import '../support/window_fixture.dart';

void main() {
  testWidgets(
    'tournament setup opens through app mode without losing the chapter',
    (tester) async {
      final app = WindowFixture(
        tournaments: ScriptedTournaments(),
        launchTournament: (_) async => const StartFailed('not launched'),
      );
      addTearDown(app.dispose);
      await app.pumpShell(tester);
      await app.requests.open(kidMain);
      final chapter = app.parts.session.chapter;
      app.requests.switchTo(Mode.engineTournament);
      await tester.pumpAndSettle();
      expect(find.text('No tournaments yet'), findsOneWidget);
      await tester.tap(find.text('New tournament'));
      await tester.pumpAndSettle();
      expect(find.text('Start new run'), findsOneWidget);
      expect(find.text('Games per pairing'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'Name'), '');
      await tester.tap(find.text('Start new run'));
      await tester.pumpAndSettle();
      expect(find.text('Name the tournament.'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await app.requests.back();
      await tester.pumpAndSettle();
      expect(app.requests.mode, Mode.repertoires);
      expect(app.parts.session.chapter, same(chapter));
      expect(tester.takeException(), isNull);
    },
  );
}

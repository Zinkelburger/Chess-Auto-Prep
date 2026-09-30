import 'package:chess_auto_prep/chess/tournament/result.dart';
import 'package:chess_auto_prep/app/mode.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/scripted_tournaments.dart';
import '../support/window_fixture.dart';

void main() {
  testWidgets(
    'open requests select outside work without replacing the workspace document',
    (tester) async {
      final store = ScriptedTournaments();
      addTearDown(store.dispose);
      Tournament match(String id) => Tournament({
        'id': id,
        'config': {
          'name': id,
          'engines': [
            {'name': 'Alpha'},
            {'name': 'Beta'},
          ],
        },
        'status': 'completed',
        'games': [
          {
            'whiteIndex': 0,
            'blackIndex': 1,
            'whiteName': 'Alpha',
            'blackName': 'Beta',
            'result': 'whiteWins',
          },
        ],
      });
      store.records['outside'] = match('outside');
      store.request = 'outside';
      final app = WindowFixture(
        tournaments: store,
        launchTournament: (_, _) async => const StartFailed('not launched'),
      );
      addTearDown(app.dispose);
      await app.pumpShell(tester);
      await app.requests.open(kidMain);
      final chapter = app.parts.session.chapter;
      await app.parts.tournaments!.listen();
      await tester.pumpAndSettle();
      expect(app.requests.mode, Mode.engineTournament);
      expect(app.parts.session.chapter, same(chapter));
      expect(app.parts.tournaments!.selected!.id, 'outside');
      expect(find.text('vs Alpha'), findsOneWidget);
      expect(
        find.text('2 s / move · Round robin · 10 games per pairing'),
        findsOneWidget,
      );
      await tester.tap(find.text('Show final positions'));
      await tester.pumpAndSettle();
      expect(app.parts.settings.value.tournamentFinalPositions, isFalse);
      app.requests.switchTo(Mode.study);
      store.records['new'] = match('new');
      store.request = 'new';
      store.updates.add(null);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 601));
      await tester.pumpAndSettle();
      expect(app.requests.mode, Mode.engineTournament);
      expect(app.parts.tournaments!.selected!.id, 'new');
      expect(app.parts.session.chapter, same(chapter));
      store.request = 'missing';
      await app.parts.tournaments!.refresh();
      await tester.pumpAndSettle();
      expect(
        find.textContaining('No tournament called "missing"'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'tournament setup opens through app mode without losing the chapter',
    (tester) async {
      final app = WindowFixture(
        tournaments: ScriptedTournaments(),
        launchTournament: (_, _) async => const StartFailed('not launched'),
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

// The top of the Findings list: the engine run's button, how far a run is
// and what the last one came to, the findings put aside, and the settings
// of the next run folded beside the button. (A finding row is in
// findings_row_test.dart; putting one aside in shell_players_test.dart.)
import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/engines/engine_line.dart';
import 'package:chess_auto_prep/features/players/findings_view.dart';
import 'package:chess_auto_prep/features/players/player_games.dart';
import 'package:chess_auto_prep/features/players/player_hunt.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/window_fixture.dart';

PlayerWeakness _finding() => PlayerWeakness(
  PlayerPosition(fen: Fen.initial, side: Side.white, line: const [], ply: 0),
  const Centipawns(-90),
  const ['g1f3'],
  false,
);

void main() {
  late WindowFixture w;
  setUp(() => w = WindowFixture());
  tearDown(() => w.dispose());

  final shown = <bool>[];

  Future<void> show(
    WidgetTester tester, {
    PlayerHunt? hunt,
    int dismissed = 0,
    bool showDismissed = false,
  }) async {
    shown.clear();
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          // As the column hosts it: rebuilt when the run or the games change.
          body: ListenableBuilder(
            listenable: Listenable.merge([
              w.parts.players.analysis,
              hunt ?? w.parts.players.hunt,
            ]),
            builder: (context, _) => SingleChildScrollView(
              child: EngineRun(
                analysis: w.parts.players.analysis,
                hunt: hunt ?? w.parts.players.hunt,
                dismissed: dismissed,
                showDismissed: showDismissed,
                onShowDismissed: shown.add,
              ),
            ),
          ),
        ),
      ),
    );
  }

  ButtonStyleButton button(WidgetTester tester, String label) =>
      tester.widget<ButtonStyleButton>(
        find
            .ancestor(
              of: find.text(label),
              matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
            )
            .first,
      );

  testWidgets('before a run, says what the button looks for, and is off '
      'while the games are read', (tester) async {
    await show(tester);
    expect(button(tester, 'Analyze with engine').onPressed, isNotNull);
    expect(
      find.text(
        'Finds positions this player handles badly, and strong replies '
        'their opponents never tried.',
      ),
      findsOneWidget,
    );
    w.parts.players.analysis.busy = true;
    await show(tester);
    expect(button(tester, 'Analyze with engine').onPressed, isNull);
    w.parts.players.analysis.busy = false;
  });

  testWidgets('a run says how far it is and what it found so far, and the '
      'button stops it', (tester) async {
    final hunt = w.parts.players.hunt
      ..running = true
      ..done = 3
      ..total = 10;
    await show(tester);
    expect(find.text('Stop · 3 / 10'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    hunt.findings = [_finding()];
    await show(tester);
    expect(find.text('1 finding so far'), findsOneWidget);
    hunt.findings = [_finding(), _finding()];
    await show(tester);
    expect(find.text('2 findings so far'), findsOneWidget);
    await tester.tap(find.text('Stop · 3 / 10'));
    expect(hunt.running, isFalse);
  });

  testWidgets('a finished run says how many positions it checked and what '
      'it found', (tester) async {
    final hunt = w.parts.players.hunt
      ..done = 25
      ..total = 25;
    await show(tester);
    expect(find.text('25 positions checked · no findings'), findsOneWidget);
    hunt.findings = [_finding()];
    await show(tester);
    expect(find.text('25 positions checked · 1 finding'), findsOneWidget);
    hunt.findings = [_finding(), _finding()];
    await show(tester);
    expect(find.text('25 positions checked · 2 findings'), findsOneWidget);
  });

  testWidgets('the findings put aside are counted and shown on request, and '
      'the list goes back', (tester) async {
    w.parts.players.hunt
      ..done = 5
      ..total = 5
      ..findings = [_finding()];
    await show(tester);
    expect(button(tester, 'Dismissed (0)').onPressed, isNull);
    await show(tester, dismissed: 2);
    await tester.tap(find.text('Dismissed (2)'));
    expect(shown, [true]);
    await show(tester, showDismissed: true);
    await tester.tap(find.text('Back to findings'));
    expect(shown, [false]);
  });

  testWidgets('a problem and a practical warning are said', (tester) async {
    w.parts.players.hunt
      ..error = 'The engine stopped.'
      ..practicalWarning = 'Maia could not read 2 positions.';
    await show(tester);
    expect(find.text('The engine stopped.'), findsOneWidget);
    expect(find.text('Maia could not read 2 positions.'), findsOneWidget);
  });

  testWidgets('the gear opens the next run\'s settings, which change it', (
    tester,
  ) async {
    final hunt = w.parts.players.hunt;
    await show(tester);
    expect(find.text('Depth'), findsNothing);
    await tester.tap(find.byTooltip('Analysis settings'));
    await tester.pump();
    expect(find.byTooltip('Hide the analysis settings'), findsOneWidget);
    await tester.tap(find.byTooltip('Increase Depth'));
    await tester.pump();
    expect(hunt.depth, 15);
    await tester.tap(find.byTooltip('Increase Positions to check'));
    await tester.pump();
    expect(hunt.limit, 125);
    expect(find.text('Player rating'), findsNothing);
    await tester.tap(find.text('Include practical chances'));
    await tester.pump();
    expect(hunt.practical, isTrue);
    await tester.tap(find.byTooltip('Increase Player rating'));
    await tester.pump();
    expect(hunt.rating, 1900);
    await tester.tap(find.byTooltip('Increase Positions to probe'));
    await tester.pump();
    expect(hunt.probes, 11);
    await tester.tap(find.byTooltip('Hide the analysis settings'));
    await tester.pump();
    expect(find.text('Depth'), findsNothing);
  });

  testWidgets('without the Maia model, practical chances say why they are '
      'not offered', (tester) async {
    final hunt = PlayerHunt(
      w.parts.players.analysis,
      () => w.parts.env.startEngine(),
      reports: w.parts.env.playerReports,
    );
    addTearDown(hunt.dispose);
    await show(tester, hunt: hunt);
    await tester.tap(find.byTooltip('Analysis settings'));
    await tester.pump();
    expect(
      find.text(
        'Practical chances need the Maia model, which is not installed.',
      ),
      findsOneWidget,
    );
    expect(find.text('Include practical chances'), findsNothing);
  });

  testWidgets('practical chances cannot be switched while a run goes', (
    tester,
  ) async {
    w.parts.players.hunt.running = true;
    await show(tester);
    await tester.tap(find.byTooltip('Analysis settings'));
    await tester.pump();
    final check = tester.widget<Checkbox>(find.byType(Checkbox));
    expect(check.onChanged, isNull);
    w.parts.players.hunt.running = false;
  });
}

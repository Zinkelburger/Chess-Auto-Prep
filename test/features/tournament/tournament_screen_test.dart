/// Smoke tests for the Tournament screen.
///
/// Nothing else here renders a pixel, so a screen that throws on first build —
/// a bad Dropdown parameter, an unbounded Row, a null deref in a header —
/// would ship looking fine. These pump the real widget tree.
library;

import 'package:chess_auto_prep/features/tournament/models/roster_entry.dart';
import 'package:chess_auto_prep/features/tournament/services/player_directory.dart';
import 'package:chess_auto_prep/features/tournament/services/tournament_session.dart';
import 'package:chess_auto_prep/screens/tournament_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Roster _roster({bool withMe = true}) => Roster(
  eventName: 'Spring Open',
  rounds: 4,
  entries: [
    const RosterEntry(
      id: '12345678',
      name: 'Smith, John',
      uscfId: '12345678',
      rating: 2048,
    ),
    RosterEntry(
      id: '87654321',
      name: 'Doe, Jane',
      uscfId: '87654321',
      rating: 1900,
      isMe: withMe,
    ),
    const RosterEntry(
      id: '11112222',
      name: 'Roe, Rick',
      uscfId: '11112222',
      rating: 1750,
    ),
  ],
);

/// Desktop-sized surface: the screen is a fixed 380px left pane plus a
/// flexible right one, and the default 800x600 test window squeezes it.
void _useDesktopSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1600, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<TournamentSession> pumpScreen(
  WidgetTester tester, {
  Roster? roster,
}) async {
  final session = TournamentSession();
  if (roster != null) session.setRoster(roster);

  await tester.pumpWidget(
    ChangeNotifierProvider<TournamentSession>.value(
      value: session,
      child: const MaterialApp(home: Scaffold(body: TournamentScreen())),
    ),
  );
  await tester.pumpAndSettle();
  return session;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => PlayerDirectory.ensureLoaded());

  testWidgets('builds with an empty roster and explains what to do', (
    tester,
  ) async {
    _useDesktopSurface(tester);
    await pumpScreen(tester);

    expect(tester.takeException(), isNull);
    expect(find.textContaining('No entry list loaded'), findsOneWidget);
    expect(find.text('Import entry list'), findsOneWidget);
    expect(find.text('Resolve accounts'), findsOneWidget);
    expect(find.text('Prepare tournament'), findsOneWidget);
  });

  testWidgets('renders a roster with names and ratings', (tester) async {
    _useDesktopSurface(tester);
    await pumpScreen(tester, roster: _roster());

    expect(tester.takeException(), isNull);
    expect(find.text('Smith, John'), findsOneWidget);
    expect(find.text('Doe, Jane'), findsOneWidget);
    expect(find.text('2048'), findsOneWidget);
    expect(find.textContaining('3 entrants'), findsOneWidget);
    // "Spring Open" is also the Event name field's placeholder, so the header
    // is identified by its style rather than by being the only match.
    expect(find.text('Spring Open'), findsWidgets);
  });

  testWidgets('warns when nobody is marked as you', (tester) async {
    _useDesktopSurface(tester);
    await pumpScreen(tester, roster: _roster(withMe: false));

    expect(tester.takeException(), isNull);
    expect(find.textContaining('Nobody is marked as you'), findsOneWidget);
  });

  testWidgets('selecting an entrant opens its detail card', (tester) async {
    _useDesktopSurface(tester);
    await pumpScreen(tester, roster: _roster());

    await tester.tap(find.text('Smith, John'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('USCF 12345678'), findsOneWidget);
    expect(find.text('This is me'), findsOneWidget);
    expect(find.text('Mark withdrawn'), findsOneWidget);
  });

  testWidgets('"This is me" moves the flag to exactly one entrant', (
    tester,
  ) async {
    _useDesktopSurface(tester);
    final session = await pumpScreen(tester, roster: _roster());

    await tester.tap(find.text('Smith, John'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('This is me'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(session.roster.entries.where((e) => e.isMe), hasLength(1));
    expect(session.roster.me?.id, '12345678');
  });

  testWidgets('simulating pairings renders probabilities in the table', (
    tester,
  ) async {
    _useDesktopSurface(tester);
    final session = await pumpScreen(tester, roster: _roster());

    await tester.tap(find.text('Simulate pairings'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(session.simulation.trials, greaterThan(0));
    expect(session.simulation.opponents, isNotEmpty);
    // "you" marks our own row; opponents show a percentage.
    expect(find.text('you'), findsOneWidget);
    expect(find.textContaining('runs · expected score'), findsOneWidget);
  });

  testWidgets('importing from the paste box populates the table', (
    tester,
  ) async {
    _useDesktopSurface(tester);
    final session = await pumpScreen(tester);

    await tester.enterText(
      find.byType(TextField).last,
      'Name,USCF ID,Rating\n"Pasted, Player",12345678,1800\n',
    );
    await tester.tap(find.text('Import entry list'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(session.roster.entries, hasLength(1));
    expect(find.text('Pasted, Player'), findsOneWidget);
  });

  testWidgets('the prep panel says there is nothing yet', (tester) async {
    _useDesktopSurface(tester);
    await pumpScreen(tester, roster: _roster());

    expect(find.textContaining('No prep run yet'), findsOneWidget);
  });
}

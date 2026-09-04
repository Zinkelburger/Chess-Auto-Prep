import 'package:chess_auto_prep/features/databases/widgets/database_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The card is a form, and these are the rules the form exists to enforce.
/// The page it replaced broke each of them somewhere: a disabled button whose
/// reason lived in a banner three controls away, a store the app could not use
/// that still offered controls, and a "what it buys you" line that had nowhere
/// to go and ended up in a section subtitle shared with an unrelated store.

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

DatabaseCard _card({
  DatabaseAvailability availability = DatabaseAvailability.ready,
  String? status,
  DatabaseAction? primary,
  Widget? details,
  String? unavailableReason,
  Widget? body,
}) => DatabaseCard(
  title: 'Master games',
  icon: Icons.library_books_outlined,
  whatItIs: 'Titled-player games, kept locally.',
  whatItBuys: 'Repertoire builds use real master practice.',
  availability: availability,
  status: status,
  primary: primary,
  details: details,
  body: body,
  unavailableReason: unavailableReason,
);

void main() {
  testWidgets('a ready card states what it is and what it buys', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_card(status: '1,920,172 games')));

    expect(find.text('Master games'), findsOneWidget);
    expect(find.text('1,920,172 games'), findsOneWidget);
    expect(find.text('Titled-player games, kept locally.'), findsOneWidget);
    expect(
      find.text('Repertoire builds use real master practice.'),
      findsOneWidget,
    );
  });

  testWidgets('a card with no status says so rather than showing a blank', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(_card(availability: DatabaseAvailability.notSetUp)),
    );

    expect(find.text('Not set up'), findsOneWidget);
  });

  testWidgets('a disabled action carries its reason in a tooltip', (
    tester,
  ) async {
    var ran = false;
    await tester.pumpWidget(
      _host(
        _card(
          primary: DatabaseAction(
            label: 'Download master games',
            onRun: () => ran = true,
            disabledReason: 'A download is running.',
          ),
        ),
      ),
    );

    final tooltip = tester.widget<Tooltip>(
      find.ancestor(
        of: find.text('Download master games'),
        matching: find.byType(Tooltip),
      ),
    );
    expect(tooltip.message, 'A download is running.');

    // And it really is inert: the wrapper must absorb the tap, not merely
    // look grey.
    await tester.tap(find.text('Download master games'), warnIfMissed: false);
    await tester.pump();
    expect(ran, isFalse);
  });

  testWidgets('an enabled action is not wrapped, and runs', (tester) async {
    var ran = false;
    await tester.pumpWidget(
      _host(
        _card(
          primary: DatabaseAction(
            label: 'Check for new issues',
            onRun: () => ran = true,
          ),
        ),
      ),
    );

    await tester.tap(find.text('Check for new issues'));
    await tester.pump();
    expect(ran, isTrue);
  });

  testWidgets('an unavailable store offers nothing to press', (tester) async {
    await tester.pumpWidget(
      _host(
        _card(
          availability: DatabaseAvailability.unavailable,
          unavailableReason: 'Only available on Linux.',
          primary: DatabaseAction(label: 'Download…', onRun: () {}),
          details: const Text('knobs'),
          body: const Text('a download card'),
        ),
      ),
    );

    expect(find.text('Only available on Linux.'), findsOneWidget);
    expect(find.text('Unavailable'), findsOneWidget);
    // Controls for a store this machine cannot have are dead weight, and a
    // reader who presses one has been misled by the page.
    expect(find.text('Download…'), findsNothing);
    expect(find.text('a download card'), findsNothing);
    expect(find.text('knobs'), findsNothing);
  });

  testWidgets('settings stay behind a disclosure until asked for', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(_card(details: const Text('Years of games'))),
    );

    expect(find.text('Years of games'), findsNothing);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Years of games'), findsOneWidget);
  });

  testWidgets('only the recommended card is badged', (tester) async {
    await tester.pumpWidget(_host(_card()));
    expect(find.text('START HERE'), findsNothing);

    await tester.pumpWidget(
      _host(
        const DatabaseCard(
          title: 'Lichess evaluations',
          icon: Icons.storage_outlined,
          whatItIs: 'Positions already analysed.',
          whatItBuys: 'Builds stop waiting on the engine.',
          availability: DatabaseAvailability.notSetUp,
          recommended: true,
        ),
      ),
    );
    expect(find.text('START HERE'), findsOneWidget);
  });
}

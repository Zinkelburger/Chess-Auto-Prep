// A Bughouse hand: which pieces can be picked up, what each slot says, and
// the − and + that change it.
import 'package:chess_auto_prep/chess/bughouse/table.dart';
import 'package:chess_auto_prep/features/bughouse/pocket.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<Role> picks;
  late List<(Role, int)> steps;

  setUp(() {
    picks = [];
    steps = [];
  });

  Pockets hand({int knights = 0, int bishops = 0, int pawns = 0}) {
    var pockets = Pockets.empty;
    for (var i = 0; i < knights; i++) {
      pockets = pockets.increment(Side.white, Role.knight);
    }
    for (var i = 0; i < bishops; i++) {
      pockets = pockets.increment(Side.white, Role.bishop);
    }
    for (var i = 0; i < pawns; i++) {
      pockets = pockets.increment(Side.white, Role.pawn);
    }
    return pockets;
  }

  Future<void> pump(
    WidgetTester tester,
    Pockets pockets, {
    bool live = false,
    Role? picked,
    bool withSteps = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: Center(
            child: PocketWell(
              pockets: pockets,
              side: Side.white,
              owner: 'White',
              square: 48,
              seat: Seat.a,
              live: live,
              picked: picked,
              onPick: picks.add,
              onStep: withSteps ? (role, by) => steps.add((role, by)) : null,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder slot(Role role) => find.byKey(ValueKey(('reserve', Seat.a, role)));

  testWidgets('a held piece of the player on move can be picked up', (
    tester,
  ) async {
    await pump(tester, hand(knights: 1), live: true);
    expect(
      find.byTooltip(
        'White: 1 knight in hand · click, then click a highlighted square, '
        'or drag onto the board',
      ),
      findsOneWidget,
    );
    expect(find.byTooltip('No pawn in hand'), findsOneWidget);
    await tester.tap(slot(Role.pawn));
    await tester.tap(slot(Role.knight));
    expect(picks, [Role.knight], reason: 'nothing held, nothing picked');
  });

  testWidgets('a player not on move cannot pick up, and is told why', (
    tester,
  ) async {
    await pump(tester, hand(knights: 1));
    expect(
      find.byTooltip('White: 1 knight in hand · waiting for turn'),
      findsOneWidget,
    );
    expect(find.byTooltip('No pawn in hand'), findsOneWidget);
    await tester.tap(slot(Role.knight));
    expect(picks, isEmpty);
  });

  testWidgets('the piece picked up is the one marked', (tester) async {
    final semantics = tester.ensureSemantics();
    await pump(
      tester,
      hand(knights: 1, bishops: 1),
      live: true,
      picked: Role.knight,
    );
    expect(
      tester.getSemantics(
        find.bySemanticsLabel(RegExp('^White: 1 knight in hand')),
      ),
      isSemantics(isSelected: true),
    );
    expect(
      tester.getSemantics(
        find.bySemanticsLabel(RegExp('^White: 1 bishop in hand')),
      ),
      isSemantics(isSelected: false),
    );
    semantics.dispose();
  });

  testWidgets('− only for a piece held, + only below the limit', (
    tester,
  ) async {
    await pump(tester, hand(knights: 1, pawns: handLimit), withSteps: true);
    expect(find.byTooltip('One knight fewer for White'), findsOneWidget);
    expect(find.byTooltip('One more knight for White'), findsOneWidget);
    expect(find.byTooltip('One bishop fewer for White'), findsNothing);
    expect(find.byTooltip('One more bishop for White'), findsOneWidget);
    expect(find.byTooltip('One more pawn for White'), findsNothing);
    expect(find.byTooltip('One pawn fewer for White'), findsOneWidget);
  });

  testWidgets('a slot\'s − and + take clicks while one has the focus, and '
      'not once it has gone', (tester) async {
    await pump(tester, hand(knights: 1), withSteps: true);
    final more = find.byTooltip('One more knight for White');
    await tester.tap(more, warnIfMissed: false);
    expect(steps, isEmpty, reason: 'hidden until pointed at or focused');
    // The knight's −, then its +.
    final node = Focus.of(
      tester.element(find.descendant(of: more, matching: find.byType(Icon))),
    );
    node.requestFocus();
    await tester.pumpAndSettle();
    await tester.tap(more);
    expect(steps, [(Role.knight, 1)]);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.tap(more, warnIfMissed: false);
    expect(steps, [(Role.knight, 1)]);
  });

  testWidgets('a pocket taken down while a step has the focus is left alone', (
    tester,
  ) async {
    await pump(tester, hand(knights: 1), withSteps: true);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('the floated board names each hand where it stands', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: Center(
            child: SizedBox.fromSize(
              size: BughousePreviewBoard.size,
              child: const BughousePreviewBoard(
                position: Crazyhouse.initial,
                orientation: Side.white,
                lastMove: 'e2e4',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final white = tester.getRect(
      find.bySemanticsLabel(RegExp('^White: 0 pawn in hand')),
    );
    final black = tester.getRect(
      find.bySemanticsLabel(RegExp('^Black: 0 pawn in hand')),
    );
    expect(black.top, lessThan(white.top), reason: 'White below');
    semantics.dispose();
  });
}

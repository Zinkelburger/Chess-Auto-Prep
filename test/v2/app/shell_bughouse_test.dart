import 'package:chess_auto_prep/v2/chess/bughouse/hivemind.dart';
import 'package:chess_auto_prep/v2/chess/bughouse/table.dart';
import 'package:chess_auto_prep/v2/storage/bughouse_books.dart';
import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart' show Role, Side, Square;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/window_fixture.dart';

/// The Bughouse lab in the window: two boards, the chips and each board's
/// scored moves, over a scripted engine, book and archive.
void main() {
  late WindowFixture w;
  setUp(() => w = WindowFixture());
  tearDown(() => w.dispose());

  /// The start in the book: e4 and d4 on board 1, e4 on board 2, for
  /// `even`; e4 on board 1 also for `ahead`.
  void startInBook() =>
      w.bughouse.book.positions[TablePosition.initial.bookKey] =
          const HivemindFound({
            (BoardNumber.one, 'e2e4'): {
              ClockCase.even: (score: TableScore(score: 0.21), pv: 'A e4'),
              ClockCase.abMaySit: (score: TableScore(score: 2.47), pv: 'A e4'),
            },
            (BoardNumber.one, 'd2d4'): {
              ClockCase.even: (score: TableScore(score: 0.13), pv: 'A d4'),
            },
            (BoardNumber.two, 'e2e4'): {
              ClockCase.even: (score: TableScore(score: -0.40), pv: 'D e4'),
            },
          });

  Future<void> toLab(WidgetTester tester) async {
    await w.pumpShell(tester);
    await tester.tap(find.text('Repertoire builder'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bughouse lab'));
    await tester.pumpAndSettle();
  }

  /// The row of [san] in [board]'s table.
  Finder row(BoardNumber board, String san) => find.descendant(
    of: find.byKey(ValueKey(('moves', board))),
    matching: find.text(san),
  );

  testWidgets(
    'the lab is in the mode menu only when the build has the engine',
    (tester) async {
      w.bughouse.bundled = false;
      await w.pumpShell(tester);
      await tester.tap(find.text('Repertoire builder'));
      await tester.pumpAndSettle();
      expect(find.text('Bughouse lab'), findsNothing);
      expect(find.text('Tactics'), findsOneWidget);
    },
  );

  testWidgets('a position in the book is scored at once; the Time chips '
      'switch the clock', (tester) async {
    startInBook();
    await toLab(tester);
    expect(find.text('Player A'), findsOneWidget);
    expect(find.text('Player D'), findsOneWidget);
    expect(find.text('Move: Player A'), findsOneWidget);
    expect(find.text('Move: Player D'), findsOneWidget);
    expect(find.text('From the Hivemind book.'), findsOneWidget);
    expect(find.text('+0.21'), findsOneWidget);
    // Board 2's mover is D, of C + D: A + B's −0.40 reads +0.40 for D.
    expect(find.text('+0.40'), findsOneWidget);
    await tester.tap(find.text('A + B may sit'));
    await tester.pumpAndSettle();
    expect(find.text('+2.47'), findsOneWidget);
    expect(find.text('+0.21'), findsNothing);
    expect(w.bughouse.starts, 0);
  });

  testWidgets('a position the book lacks is searched by the engine', (
    tester,
  ) async {
    await toLab(tester);
    expect(
      find.text('Not in the book · Hivemind scored the likeliest moves.'),
      findsOneWidget,
    );
    expect(w.bughouse.engine.asked, isNotEmpty);
  });

  testWidgets('a table row plays its move; a reserve piece drops on a square', (
    tester,
  ) async {
    startInBook();
    await toLab(tester);
    await tester.tap(row(BoardNumber.one, 'e4'));
    await tester.pumpAndSettle();
    expect(w.lab.line.of(BoardNumber.one).single.san, 'e4');
    w.lab
      ..play(BoardNumber.one, 'd7d5')
      ..play(BoardNumber.one, 'e4d5')
      ..play(BoardNumber.two, 'e2e4');
    await tester.pumpAndSettle();
    // B, Black on board 2, holds the pawn board 1 took: pick it up, then
    // click d5.
    await tester.tap(
      find.byKey(const ValueKey(('reserve', Seat.b, Role.pawn))),
    );
    await tester.pumpAndSettle();
    await tester.tapAt(squareCenter(tester, BoardNumber.two, Square.d5));
    await tester.pumpAndSettle();
    expect(w.lab.line.of(BoardNumber.two).last.san, 'P@d5');
    expect(find.text('P@d5'), findsWidgets);
  });

  testWidgets('a drop on a square that will not take it is refused in words', (
    tester,
  ) async {
    await toLab(tester);
    w.lab.loadDualFen(
      'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[N] w KQkq - 0 1|'
      'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey(('reserve', Seat.a, Role.knight))),
    );
    await tester.pumpAndSettle();
    await tester.tapAt(squareCenter(tester, BoardNumber.one, Square.e2));
    await tester.pumpAndSettle();
    expect(find.text('That drop is not legal.'), findsOneWidget);
  });

  testWidgets(
    'pointing at a row draws it on its board; leaving takes it away',
    (tester) async {
      startInBook();
      await toLab(tester);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(row(BoardNumber.one, 'd4')));
      await tester.pumpAndSettle();
      expect(w.lab.preview.value, {BoardNumber.one: 'd2d4'});
      await mouse.moveTo(Offset.zero);
      await tester.pumpAndSettle();
      expect(w.lab.preview.value, isNull);
    },
  );

  testWidgets('the engine switch shows both teams’ lines; a line plays', (
    tester,
  ) async {
    startInBook();
    await toLab(tester);
    await tester.tap(find.byTooltip('Toggle engine (E)'));
    await tester.pumpAndSettle();
    expect(find.text('A + B'), findsOneWidget);
    expect(find.text('C + D'), findsOneWidget);
    expect(find.text('0.00'), findsWidgets);
    await tester.tap(find.text('A Na3'));
    await tester.pumpAndSettle();
    expect(w.lab.line.moves, hasLength(1));
  });

  testWidgets('an engine that will not start is said in the status line', (
    tester,
  ) async {
    w.bughouse.startFailure = 'This build has no bughouse engine.';
    await toLab(tester);
    final status = tester.widget<Text>(
      find.text('This build has no bughouse engine.'),
    );
    expect(
      status.style?.color,
      Theme.of(tester.element(find.byType(Scaffold))).colorScheme.error,
    );
  });

  testWidgets('the FICS archive is under each board’s table, results for '
      'the team that played the move', (tester) async {
    w.bughouse.archive.present = true;
    w.bughouse.archive.positions[TablePosition.initial.bookKey] = (
      games: 1200,
      moves: [
        (
          board: BoardNumber.two,
          mover: Side.white,
          san: 'd4',
          games: 1000,
          abWins: 300,
          cdWins: 600,
          draws: 100,
          unknown: 0,
          averageElo: 1900,
        ),
      ],
    );
    startInBook();
    await toLab(tester);
    expect(find.textContaining('FICS archive · 1200 games'), findsNWidgets(2));
    expect(find.text('D d4'), findsOneWidget);
    // D's team, C + D, won 600 of the 1000.
    expect(find.text('60%'), findsOneWidget);
    await tester.tap(find.text('D d4'));
    await tester.pumpAndSettle();
    expect(w.lab.line.of(BoardNumber.two).single.san, 'd4');
  });

  testWidgets('a match is asked for, played, and its games opened', (
    tester,
  ) async {
    startInBook();
    await toLab(tester);
    await tester.tap(find.text('Matches'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'No matches yet. Set a position up on the boards, then play it out.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('New match'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '10'), '1');
    await tester.enterText(find.widgetWithText(TextField, '240'), '20');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play 1 game'));
    await tester.pumpAndSettle();
    final match = w.bughouse.matches.saved.values.single;
    expect(match.games, hasLength(1));
    expect(find.textContaining('White on board 1 scored'), findsOneWidget);
    await tester.tap(find.text('Hivemind A').last);
    await tester.pumpAndSettle();
    expect(w.lab.line.moves, hasLength(20));
  });

  testWidgets('a match directory that cannot be made is said', (tester) async {
    w.bughouse.matches.failCreate = 'Permission denied';
    await toLab(tester);
    await tester.tap(find.text('Matches'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New match'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play 10 games'));
    await tester.pumpAndSettle();
    expect(
      find.text('Could not create the match directory: Permission denied'),
      findsOneWidget,
    );
  });

  testWidgets('leaving the lab quits its engine and gives Stockfish back', (
    tester,
  ) async {
    await toLab(tester);
    expect(w.analysis.pausedFor, isNotNull);
    expect(w.bughouse.engine.gone, isFalse);
    await tester.tap(find.text('Bughouse lab').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Repertoire builder').last);
    await tester.pumpAndSettle();
    expect(w.bughouse.engine.gone, isTrue);
    expect(w.analysis.pausedFor, isNull);
  });

  testWidgets('a setup box keeps the arrow keys while it is typed in', (
    tester,
  ) async {
    startInBook();
    await toLab(tester);
    await tester.tap(row(BoardNumber.one, 'e4'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey(('fen', BoardNumber.one))));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(w.lab.line.upto(BoardNumber.one), 1);
  });

  testWidgets('the arrow keys step the board last played on', (tester) async {
    startInBook();
    await toLab(tester);
    await tester.tap(row(BoardNumber.one, 'e4'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(w.lab.line.upto(BoardNumber.one), 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pumpAndSettle();
    expect(w.lab.line.upto(BoardNumber.one), 1);
  });

  testWidgets('the setup boxes set a table and count what is left to place', (
    tester,
  ) async {
    await toLab(tester);
    expect(find.text('Pieces outstanding: none'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey(('fen', BoardNumber.one))),
      '4k3/8/8/8/8/8/8/4K3 w - - 0 1',
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Pieces outstanding: White: 8P'),
      findsOneWidget,
    );
    await tester.tap(find.text('Set position'));
    await tester.pumpAndSettle();
    expect(w.lab.position.one.board.pieceAt(Square.e1)?.color, Side.white);
    expect(w.lab.line.moves, isEmpty);
  });
}

/// The middle of [square] on [board], as the board is drawn now.
Offset squareCenter(WidgetTester tester, BoardNumber board, Square square) {
  final boards = find.byType(Chessboard);
  final chessboard = boards.at(board == BoardNumber.one ? 0 : 1);
  final widget = tester.widget<Chessboard>(chessboard);
  final topLeft = tester.getTopLeft(chessboard);
  final size = tester.getSize(chessboard).width / 8;
  final white = widget.orientation == Side.white;
  final file = white ? square.file : 7 - square.file;
  final rank = white ? 7 - square.rank : square.rank;
  return topLeft + Offset((file + 0.5) * size, (rank + 0.5) * size);
}

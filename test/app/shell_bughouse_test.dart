import 'package:chess_auto_prep/chess/bughouse/hivemind.dart';
import 'package:chess_auto_prep/chess/bughouse/table.dart';
import 'package:chess_auto_prep/storage/pgn_file_import.dart';
import 'package:chess_auto_prep/storage/pgn_file_picker.dart';
import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart' show Role, Side, Square;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_input.dart';
import '../support/viewer_fixture.dart';
import '../support/window_fixture.dart';

/// The Bughouse mode in the window: one board or two, hands with + and −,
/// and the engine's lines, over a scripted engine.
void main() {
  late WindowFixture w;
  TestGesture? mouse;
  setUp(() {
    w = WindowFixture();
    mouse = null;
  });
  tearDown(() => w.dispose());

  Future<void> toBughouse(WidgetTester tester) async {
    await w.pumpShell(tester);
    await tester.tap(find.text('Repertoire builder'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bughouse'));
    await tester.pumpAndSettle();
  }

  Future<void> twoBoards(WidgetTester tester) async {
    await tester.tap(find.text('2 boards'));
    await tester.pumpAndSettle();
  }

  Future<void> engineOn(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Toggle engine (E)'));
    await tester.pumpAndSettle();
  }

  /// A hand's + or −, with the pointer over its slot so it shows.
  Future<Finder> handStep(WidgetTester tester, String tooltip) async {
    final step = find.byTooltip(tooltip);
    final at = tester.getCenter(step);
    if (mouse case final pointer?) {
      await pointer.moveTo(at);
    } else {
      final pointer = mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await pointer.addPointer(location: at);
      addTearDown(pointer.removePointer);
    }
    await tester.pump();
    return step;
  }

  testWidgets(
    'Bughouse is in the mode menu only when the build has the engine',
    (tester) async {
      w.bughouse.bundled = false;
      await w.pumpShell(tester);
      await tester.tap(find.text('Repertoire builder'));
      await tester.pumpAndSettle();
      expect(find.text('Bughouse'), findsNothing);
      expect(find.text('Tactics'), findsOneWidget);
    },
  );

  testWidgets('it opens on one board; + and − change a hand', (tester) async {
    await toBughouse(tester);
    expect(find.byType(Chessboard), findsOneWidget);
    // With one board the clock cases name the colours.
    expect(find.text('White may sit'), findsOneWidget);
    // Until the pointer is over the hand its + and − are hidden.
    await tester.tap(
      find.byTooltip('One more knight for Black'),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    expect(w.lab.position.one.pockets!.of(Side.black, Role.knight), 0);
    final more = await handStep(tester, 'One more knight for Black');
    await tester.tap(more);
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(w.lab.position.one.pockets!.of(Side.black, Role.knight), 2);
    await tester.tap(await handStep(tester, 'One knight fewer for Black'));
    await tester.pumpAndSettle();
    expect(w.lab.position.one.pockets!.of(Side.black, Role.knight), 1);
    expect(w.bughouse.starts, 0);
  });

  testWidgets('two boards show both, the sit chips, and drop across', (
    tester,
  ) async {
    await toBughouse(tester);
    await twoBoards(tester);
    expect(find.byType(Chessboard), findsNWidgets(2));
    expect(find.text('A + B may sit'), findsOneWidget);
    w.lab
      ..play(BoardNumber.one, 'e2e4')
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
    await toBughouse(tester);
    await tester.tap(await handStep(tester, 'One more knight for White'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey(('reserve', Seat.a, Role.knight))),
    );
    await tester.pumpAndSettle();
    await tester.tapAt(squareCenter(tester, BoardNumber.one, Square.e2));
    await tester.pumpAndSettle();
    expect(w.lab.line.moves, isEmpty);
  });

  testWidgets('one board: the engine searches board 1 with its partner board '
      'held still, and a line plays', (tester) async {
    await toBughouse(tester);
    await engineOn(tester);
    final asked = w.bughouse.engine.asked;
    final own = asked.firstWhere((q) => q.team == Team.ab);
    expect(own.mustMove, MustMove.one);
    expect(own.maySit, isFalse);
    // C + D get the partner board's move, so both teams are searched.
    final other = asked.firstWhere((q) => q.team == Team.cd);
    expect(other.position.turn(BoardNumber.two), Side.white);
    expect(find.text('0.00'), findsWidgets);
    expect(find.textContaining('nodes'), findsOneWidget);
    await tester.tap(find.text('1. Na3'));
    await tester.pumpAndSettle();
    expect(w.lab.line.of(BoardNumber.one).single.san, 'Na3');
    expect(w.lab.line.of(BoardNumber.two), isEmpty);
  });

  testWidgets('two boards: each board’s moves, a line plays and pointing '
      'draws it', (tester) async {
    await toBughouse(tester);
    await twoBoards(tester);
    await engineOn(tester);
    expect(find.text('A + B'), findsNothing);
    // Board 1's A and board 2's D each have their best moves.
    expect(find.text('1. Na3'), findsNWidgets(2));
    final line = find.text('1. Na3').first;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(line));
    await tester.pumpAndSettle();
    expect(w.lab.preview.value, {BoardNumber.one: 'b1a3'});
    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    expect(w.lab.preview.value, isNull);
    await tester.tap(line);
    await tester.pumpAndSettle();
    expect(w.lab.line.moves.single.san, 'Na3');
  });

  testWidgets('the sit chips decide who may sit', (tester) async {
    await toBughouse(tester);
    await twoBoards(tester);
    await tester.tap(find.text('A + B may sit'));
    await tester.pumpAndSettle();
    await engineOn(tester);
    final asked = w.bughouse.engine.asked;
    expect(asked.firstWhere((q) => q.team == Team.ab).maySit, isTrue);
    expect(asked.firstWhere((q) => q.team == Team.cd).maySit, isFalse);
  });

  testWidgets('an engine that will not start is said beside its switch', (
    tester,
  ) async {
    w.bughouse.startFailure = 'This build has no bughouse engine.';
    await toBughouse(tester);
    await engineOn(tester);
    final status = tester.widget<Text>(
      find.text('This build has no bughouse engine.'),
    );
    expect(
      status.style?.color,
      Theme.of(tester.element(find.byType(Scaffold))).colorScheme.error,
    );
  });

  testWidgets('leaving quits the engine and gives Stockfish back', (
    tester,
  ) async {
    await toBughouse(tester);
    await engineOn(tester);
    expect(w.analysis.pausedFor, isNotNull);
    expect(w.bughouse.engine.gone, isFalse);
    await tester.tap(find.text('Bughouse').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Repertoire builder').last);
    await tester.pumpAndSettle();
    expect(w.bughouse.engine.gone, isTrue);
    expect(w.analysis.pausedFor, isNull);
  });

  testWidgets('the arrow keys step the board', (tester) async {
    await toBughouse(tester);
    w.lab.play(BoardNumber.one, 'e2e4');
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(w.lab.line.upto(BoardNumber.one), 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pumpAndSettle();
    expect(w.lab.line.upto(BoardNumber.one), 1);
  });

  testWidgets('Edit board opens the board editor; the hands stay', (
    tester,
  ) async {
    await toBughouse(tester);
    await tester.tap(await handStep(tester, 'One more queen for White'));
    w.lab.play(BoardNumber.one, 'e2e4');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit board'));
    await tester.pumpAndSettle();
    expect(find.text('Edit the board'), findsOneWidget);
    await tester.tap(find.text('Use this position'));
    await tester.pumpAndSettle();
    expect(w.lab.line.moves, isEmpty);
    expect(w.lab.position.one.board.pieceAt(Square.e4)?.role, Role.pawn);
    expect(w.lab.position.one.turn, Side.black);
    expect(w.lab.position.one.pockets!.of(Side.white, Role.queen), 1);
  });

  testWidgets('Paste moves reads the window\'s clipboard', (tester) async {
    final input = ScriptedInput()..clipboardText = '1A. e4 1a. d5';
    w.dispose();
    w = WindowFixture(input: input);
    await toBughouse(tester);
    await tester.tap(find.text('Actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paste moves'));
    await tester.pumpAndSettle();
    expect(w.lab.movesText, '1A. e4 1a. d5');
  });

  group('Open BPGN', () {
    ScriptedPicker picker() => w.parts.env.viewerPicker as ScriptedPicker;
    ScriptedImport files() => w.parts.env.fileImport as ScriptedImport;

    Future<void> open(WidgetTester tester, String path) async {
      picker().answer = path;
      await tester.tap(find.text('Actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open BPGN…'));
      await tester.pumpAndSettle();
    }

    testWidgets('puts a file\'s moves on the boards', (tester) async {
      await toBughouse(tester);
      files().picked['/games/playout.bpgn'] = const PickedText(
        '[Event "Hivemind playout"]\n\n1A. e4 1B. d4 1a. e5 *\n',
      );
      await open(tester, '/games/playout.bpgn');
      expect(picker().offered.single, bpgnExtensions);
      expect(w.lab.movesText, '1A. e4 1B. d4 1a. e5');
    });

    testWidgets('says which file could not be used', (tester) async {
      await toBughouse(tester);
      await open(tester, '/games/gone.bpgn');
      expect(find.text('gone.bpgn could not be read.'), findsOneWidget);
      files().picked['/games/bad.bpgn'] = const PickedText('1A. e4 1a. Ke7');
      await open(tester, '/games/bad.bpgn');
      expect(
        find.text('Not opened: 1a. Ke7 in bad.bpgn does not play.'),
        findsOneWidget,
      );
      expect(w.lab.line.moves, isEmpty);
    });
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

// The Bughouse boards: the engine's arrows and drop rings, the wheel, a
// seat's clock without a name, and the last move after a transposition.
import 'package:chess_auto_prep/chess/bughouse/hypebeast.dart';
import 'package:chess_auto_prep/chess/bughouse/table.dart';
import 'package:chess_auto_prep/engines/hypebeast_engine.dart';
import 'package:chess_auto_prep/features/bughouse/bughouse_lab.dart';
import 'package:chess_auto_prep/features/bughouse/bughouse_screen.dart';
import 'package:chess_auto_prep/features/bughouse/lab_engine.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:chess_auto_prep/workspace/board/board_view.dart';
import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart' show NormalMove, Square;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_bughouse.dart';

void main() {
  late BughouseLab lab;
  late ScriptedHypeBeast hypebeast;
  late LabEngine engine;

  void build() {
    lab = BughouseLab();
    hypebeast = ScriptedHypeBeast();
    engine = LabEngine(
      lab: lab,
      cores: 4,
      startEngine: () async => HypeBeastStarted(hypebeast),
    );
    addTearDown(() {
      engine.dispose();
      lab.dispose();
    });
  }

  Future<void> pump(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: BughouseScreen(lab: lab, engine: engine),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Board 1's search answers [lines], each a first move and its score
  /// from the side to move (none for an unscored move).
  Future<void> engineSays(
    WidgetTester tester,
    List<(String, int?)> lines,
  ) async {
    hypebeast.answer = (question) => question.board == BoardNumber.one
        ? HypeBeastSearched(
            decision: SeatDecision(lines.first.$1),
            report: SeatReport(
              lines: [
                for (final (i, (uci, cp)) in lines.indexed)
                  SeatLine(
                    multipv: i + 1,
                    depth: 12,
                    cp: cp,
                    nodes: 800,
                    pv: [uci],
                  ),
              ],
              nodes: 800,
            ),
          )
        : firstMoves(question);
    engine
      ..open()
      ..toggle();
    await tester.pumpAndSettle();
  }

  Chessboard board(WidgetTester tester) =>
      tester.widget<Chessboard>(find.byType(Chessboard).first);

  testWidgets('a move close behind the best is a grey arrow; one far behind '
      'has none', (tester) async {
    build();
    await pump(tester);
    await engineSays(tester, const [
      ('e2e4', 200),
      ('d2d4', 190),
      ('g1f3', -2000),
    ]);
    final arrows = tester
        .widget<BoardArrows>(find.byType(BoardArrows).first)
        .engine;
    expect(arrows.map((a) => a.to), [Square.e4, Square.d4]);
    expect(arrows.map((a) => a.colour), [engineBestArrow, engineOtherArrow]);
    // Ten centipawns behind is all but level: an alternative's full width.
    expect(arrows.last.width, 12);
  });

  testWidgets('a move without a score draws no arrow', (tester) async {
    build();
    await pump(tester);
    await engineSays(tester, const [('e2e4', 200), ('d2d4', null)]);
    final arrows = tester
        .widget<BoardArrows>(find.byType(BoardArrows).first)
        .engine;
    expect(arrows.map((a) => a.to), [Square.e4]);
  });

  testWidgets('the best drop is ringed in the best arrow\'s colour', (
    tester,
  ) async {
    build();
    lab.loadDualFen(
      'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[N] w KQkq - 0 1|'
      'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] w KQkq - 0 1',
    );
    await pump(tester);
    await engineSays(tester, const [('N@e4', 200)]);
    final rings = board(tester).shapes.whereType<Circle>();
    expect(rings.where((c) => c.orig == Square.e4).map((c) => c.color), [
      engineBestArrow,
    ]);
  });

  testWidgets('the wheel steps one move; a sideways scroll steps none', (
    tester,
  ) async {
    build();
    lab
      ..play(BoardNumber.one, 'e2e4')
      ..play(BoardNumber.one, 'e7e5')
      ..play(BoardNumber.one, 'g1f3')
      ..goTo(BoardNumber.one, null);
    await pump(tester);
    final centre = tester.getCenter(find.byType(Chessboard));
    Future<void> scroll(Offset by) async {
      await tester.sendEventToBinding(
        PointerScrollEvent(position: centre, scrollDelta: by),
      );
      await tester.pumpAndSettle();
    }

    await scroll(const Offset(0, 40));
    expect(lab.line.upto(BoardNumber.one), 1);
    await scroll(const Offset(40, 0));
    expect(lab.line.upto(BoardNumber.one), 1);
  });

  testWidgets('a game that names no one still shows its clocks', (
    tester,
  ) async {
    build();
    lab.pasteMoves(
      '[TimeControl "180+0"]\n\n1A. e4 {179.0} 1a. d5 {170.0} *\n',
      file: 'clocks.bpgn',
    );
    expect(lab.game?.name(Seat.a), isNull);
    await pump(tester);
    // Board 1 alone: its two seats.
    expect(find.text('3:00'), findsNWidgets(2));
  });

  testWidgets('the same position by another order shows its own last move', (
    tester,
  ) async {
    build();
    lab.play(BoardNumber.one, 'g1f3');
    lab
      ..play(BoardNumber.one, 'g8f6')
      ..play(BoardNumber.one, 'b1c3');
    final main = lab.line.at(BoardNumber.one);
    lab
      ..goTo(BoardNumber.one, null)
      ..play(BoardNumber.one, 'b1c3')
      ..play(BoardNumber.one, 'g8f6')
      ..play(BoardNumber.one, 'g1f3');
    final transposed = lab.line.at(BoardNumber.one);
    lab.goTo(BoardNumber.one, main);
    await pump(tester);
    expect(
      board(tester).controller.lastMove,
      const NormalMove(from: Square.b1, to: Square.c3),
    );
    lab.goTo(BoardNumber.one, transposed);
    await tester.pumpAndSettle();
    expect(
      board(tester).controller.lastMove,
      const NormalMove(from: Square.g1, to: Square.f3),
    );
  });
}

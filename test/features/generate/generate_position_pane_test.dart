import 'dart:async';

import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/core/generation_session_controller.dart';
import 'package:chess_auto_prep/features/generate/widgets/generate_position_pane.dart';
import 'package:chess_auto_prep/services/eval/db_move_list.dart';
import 'package:chess_auto_prep/utils/chess_utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('depth and cores apply to position and per-move computation', (
    tester,
  ) async {
    final gen = GenerationSessionController();
    addTearDown(gen.dispose);
    final calls = <({String? san, int depth, int cores})>[];
    final coverageCalls = <(int, double)>[];
    String? played;
    var booksOpened = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: GeneratePositionPane(
              fen: kStandardStartFen,
              databaseName: 'My book / Main',
              generation: gen,
              onGenerate:
                  ({
                    String? moveSan,
                    required int plies,
                    required int cores,
                    required int engineMoves,
                    required double maiaCoverage,
                  }) async {
                    calls.add((san: moveSan, depth: plies, cores: cores));
                    coverageCalls.add((engineMoves, maiaCoverage));
                    return null;
                  },
              onPlayMove: (san) => played = san,
              onPlanLines: () {},
              onBuildChessDb: () => booksOpened++,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('build-chessdb-repertoire')));
    expect(booksOpened, 1);
    expect(calls, isEmpty);
    expect(find.text('—'), findsWidgets);
    expect(
      find.text('Top 4 engine + 60% Maia moves · scores for White'),
      findsOneWidget,
    );
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('generate-engine-moves')),
        matching: find.byTooltip('More'),
      ),
    );
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('generate-maia-coverage')),
        matching: find.byTooltip('More'),
      ),
    );
    await tester.enterText(find.byType(TextFormField).at(0), '3');
    await tester.enterText(find.byType(TextFormField).at(1), '1');
    await tester.tap(find.text('Generate'));
    await tester.pump();
    expect(calls.single, (san: null, depth: 3, cores: 1));
    expect(coverageCalls.single, (5, .65));
    await tester.tap(find.byTooltip('Evaluate Na3 and save engine PV'));
    await tester.pump();
    expect(calls.last, (san: 'Na3', depth: 3, cores: 1));
    await tester.tap(find.text('Na3'));
    expect(played, 'Na3');
    expect(tester.takeException(), isNull);
    await tester.enterText(find.byType(TextFormField).at(0), '0');
    await tester.tap(find.text('Generate'));
    await tester.pump();
    expect(calls.length, 2);
    expect(find.text('1–60'), findsOneWidget);
  });
  testWidgets('late ChessDB results cannot populate a different position', (
    tester,
  ) async {
    final gen = GenerationSessionController();
    addTearDown(gen.dispose);
    final pending = <String, Completer<DbMoveList>>{};
    Future<DbMoveList> lookup(String fen) =>
        (pending[fen] = Completer()).future;
    Widget pane(String fen) => MaterialApp(
      home: Scaffold(
        body: GeneratePositionPane(
          fen: fen,
          databaseName: 'Main',
          generation: gen,
          lookupChessDb: lookup,
          onGenerate:
              ({
                String? moveSan,
                required int plies,
                required int cores,
                required int engineMoves,
                required double maiaCoverage,
              }) async => null,
          onPlayMove: (_) {},
          onPlanLines: () {},
        ),
      ),
    );
    await tester.pumpWidget(pane(kStandardStartFen));
    await tester.tap(find.text('ChessDB'));
    await tester.pump();
    final next = playUciMove(kStandardStartFen, 'e2e4')!;
    await tester.pumpWidget(pane(next));
    pending[kStandardStartFen]!.complete(
      const DbMoveList(
        source: DbMoveSource.chessDbApi,
        moves: [DbMove(uci: 'e2e4', stmCp: 1234)],
      ),
    );
    pending[next]!.complete(
      const DbMoveList(
        source: DbMoveSource.chessDbApi,
        moves: [DbMove(uci: 'a7a6', stmCp: 25)],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('+12.34'), findsNothing);
    expect(find.text('-0.25'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

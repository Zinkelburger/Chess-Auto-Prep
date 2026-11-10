import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/storage/settings_store.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:chess_auto_prep/workspace/analysis/engine_analysis.dart';
import 'package:chess_auto_prep/workspace/board/board_column.dart';
import 'package:chess_auto_prep/workspace/board/board_view.dart';
import 'package:chess_auto_prep/workspace/board/move_field.dart';
import 'package:chess_auto_prep/workspace/reading/move_note.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';
import '../support/session_fixture.dart';

/// The board and the note under it share the column's height: the note has
/// its room while the board is big enough to play on, and gives it up in a
/// window too short for both.
void main() {
  late SessionFixture fixture;
  late EngineAnalysis analysis;
  late SettingsStore settings;
  late MoveEntry moves;

  setUp(() async {
    fixture = await openSession(blackChapter);
    analysis = EngineAnalysis(
      fixture.session,
      () async => const StartFailed('test'),
    );
    settings = SettingsStore();
    moves = MoveEntry();
  });

  tearDown(() {
    moves.dispose();
    settings.dispose();
    analysis.dispose();
    fixture.dispose();
  });

  Future<void> pump(WidgetTester tester, double height) async {
    await tester.binding.setSurfaceSize(Size(800, height));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 420,
              height: height,
              child: BoardAndCounter(
                session: fixture.session,
                settings: settings,
                analysis: analysis,
                onMove: (_) {},
                counter: false,
                moves: moves,
                noteEditable: true,
                engine: (_) => const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('a tall column keeps the note under a board with room to '
      'play on', (tester) async {
    await pump(tester, 900);
    expect(find.byType(MoveNote), findsOneWidget);
    expect(
      tester.getSize(find.byType(BoardView)).width,
      greaterThanOrEqualTo(boardCrampedSide),
    );
  });

  testWidgets('a short column gives the note\'s room to the board', (
    tester,
  ) async {
    await pump(tester, 600);
    expect(find.byType(MoveNote), findsNothing);
    expect(
      tester.getSize(find.byType(BoardView)).width,
      greaterThan(boardCrampedSide),
    );
  });
}

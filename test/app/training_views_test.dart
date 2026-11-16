// Tactics and My games as modes: Tactics neither heads the card nor
// counts games, Esc ends a sitting, and a puzzle analyzed on a board of
// its own comes up at the puzzle, or at the start of a game that never
// reaches it; My games walks only its own list and asks for a username to
// review games, not to make puzzles.
import 'package:chess_auto_prep/app/mode.dart';
import 'package:chess_auto_prep/app/training_views.dart';
import 'package:chess_auto_prep/features/tactics/tactics_panel.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_store.dart';
import '../support/tactics_fixture.dart';
import '../support/window_fixture.dart';

void main() {
  late WindowFixture w;
  setUp(() => w = WindowFixture());
  tearDown(() => w.dispose());

  TacticsView tactics() {
    final view = TacticsView(w.parts.workspace, w.requests, w.parts.training);
    addTearDown(view.dispose);
    return view;
  }

  MyGamesView myGames() {
    final view = MyGamesView(w.parts.workspace, w.requests, w.parts.training);
    addTearDown(view.dispose);
    return view;
  }

  test('Tactics neither heads the card nor counts the games', () {
    final view = tactics();
    expect(view.header, isFalse);
    expect(view.gameCounter, isFalse);
  });

  test('Esc leaves nothing in Tactics until a sitting is under way, then '
      'ends it', () async {
    final view = tactics();
    expect(view.leave(), isFalse);
    await w.tactics.load();
    await w.trainer.start();
    expect(w.trainer.run, isNotNull);
    expect(view.leave(), isTrue);
    expect(w.trainer.run, isNull);
  });

  testWidgets('Esc in the window ends the sitting', (tester) async {
    await w.pumpShell(tester);
    w.requests.switchTo(Mode.tactics);
    await tester.pumpAndSettle();
    await w.tactics.load();
    await w.trainer.start();
    await tester.pumpAndSettle();
    expect(w.trainer.run, isNotNull);
    for (var i = 0; i < 3 && w.trainer.run != null; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
    }
    expect(w.trainer.run, isNull);
  });

  testWidgets('a puzzle from no game is analyzed at the puzzle', (
    tester,
  ) async {
    await w.pumpShell(tester);
    w.requests.switchTo(Mode.tactics);
    await tester.pumpAndSettle();
    final custom = w.tactics.puzzles.singleWhere(
      (puzzle) => puzzle.fen.value.startsWith('rnbqkbnr/pppppppp/8/8/3P4'),
    );
    tester.widget<TacticsPanel>(find.byType(TacticsPanel)).onAnalyze(custom);
    await tester.pumpAndSettle();
    expect(w.session.isScratch, isTrue, reason: 'a new analysis board');
    expect(w.session.cursor.value.isRoot, isTrue, reason: 'at the puzzle');
    expect(w.session.cursor.fen, custom.fen);
  });

  testWidgets('a puzzle whose game never reaches it is analyzed from the '
      "game's start", (tester) async {
    const elsewhere = '''

[Event "Default #6"]
[White "Me"]
[Black "Rival"]
[Date "2026.09.21"]
[Result "*"]
[FEN "8/8/8/4k3/8/8/4K3/8 w - - 0 1"]
[SetUp "1"]
[SourceMovetext "1. e4 e5 2. Nf3 *"]

1. Kd3 *
''';
    const text = tacticsSet + elsewhere;
    w.store.documents[tacticsRef] = Opened(text, scriptedRevision(text));
    await w.pumpShell(tester);
    w.requests.switchTo(Mode.tactics);
    await tester.pumpAndSettle();
    final puzzle = w.tactics.puzzles.singleWhere(
      (puzzle) => puzzle.fen.value.startsWith('8/8/8/4k3'),
    );
    tester.widget<TacticsPanel>(find.byType(TacticsPanel)).onAnalyze(puzzle);
    await tester.pumpAndSettle();
    expect(w.session.isScratch, isTrue);
    expect(w.session.tree?.children.single.san, 'e4');
    expect(w.session.cursor.value.isRoot, isTrue);
  });

  test('My games walks its own list, past its end too', () {
    expect(myGames().walk(1), isTrue);
    expect(myGames().walk(-1), isTrue);
    expect(myGames().gameCounter, isFalse);
  });

  testWidgets('My games asks for a username to review the games', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(body: myGames().list(const SizedBox())),
      ),
    );
    await tester.pump();
    expect(
      find.text(
        'Add your Lichess or Chess.com username to browse and review your '
        'games.',
      ),
      findsOneWidget,
    );
  });
}

import 'dart:async';

import 'package:chess_auto_prep/chess/tactics/analyzed_games.dart';
import 'package:chess_auto_prep/chess/tactics/game_ids.dart';
import 'package:chess_auto_prep/chess/tactics/mined_set.dart';
import 'package:chess_auto_prep/chess/tactics/mistake_counts.dart';
import 'package:chess_auto_prep/chess/tactics/puzzle.dart';
import 'package:chess_auto_prep/chess/tactics/source_game.dart';
import 'package:chess_auto_prep/features/tactics/source_game_pane.dart';
import 'package:chess_auto_prep/storage/my_accounts.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_store.dart';
import '../../support/window_fixture.dart';

/// The game the set's first puzzle (`lichess_abc`, 4.Qe2??) was mined
/// from, as the download saved it.
const _savedGame = '''
[Event "Rated blitz game"]
[Date "2026.09.20"]
[White "Me"]
[Black "Rival"]
[WhiteElo "2080"]
[Result "0-1"]
[GameId "lichess_abc"]

1. e4 e5 2. Bc4 Nc6 3. Qh5 Nf6 4. Qe2 Nd4 5. Qd1 0-1''';

/// The Game tab in Tactics over the app's own trainer and source games.
void main() {
  late WindowFixture w;
  final analyzed = <(Puzzle, PuzzleGame, int)>[];

  setUp(() async {
    analyzed.clear();
    w = WindowFixture();
    w.accounts.accounts[GameSite.lichess] = const Account('Me');
    await w.tactics.load();
  });
  tearDown(() => w.dispose());

  void saveGame(String game) {
    final text = '$game\n';
    w.store.documents[w.gamesCache.refFor(GameSite.lichess, 'Me')] = Opened(
      text,
      scriptedRevision(text),
    );
  }

  Future<void> pumpPane(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: SourceGamePane(
            sources: w.parts.training.sources,
            onAnalyze: (puzzle, game, ply) => analyzed.add((puzzle, game, ply)),
          ),
        ),
      ),
    );
  }

  Future<void> show(WidgetTester tester, int index) async {
    unawaited(w.trainer.show(w.tactics.at(index)!));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('with no puzzle up it asks for one; a puzzle from no game '
      'says so', (tester) async {
    await pumpPane(tester);
    expect(find.text('Play a puzzle to see its game.'), findsOneWidget);
    await show(tester, 3);
    expect(find.text('This puzzle has no game.'), findsOneWidget);
  });

  testWidgets('the game shows its players with their ratings, how it ended '
      'and when, and the puzzle\'s move marked', (tester) async {
    saveGame(_savedGame);
    await pumpPane(tester);
    await show(tester, 0);
    expect(find.text('Me (2080) – Rival'), findsOneWidget);
    expect(find.text('0-1 · 2026.09.20'), findsOneWidget);
    expect(find.text('4.Qe2??', findRichText: true), findsOneWidget);
    expect(find.text('Nd4', findRichText: true), findsOneWidget);
    expect(find.text('e5', findRichText: true), findsOneWidget);

    await tester.tap(find.text('Open on analysis board'));
    final (puzzle, game, ply) = analyzed.single;
    expect(puzzle.index, 0);
    expect(game.text, _savedGame);
    expect(ply, game.mistake, reason: 'the board before the mistake');
    expect(game.sans[ply], 'Qe2');

    // A move clicked opens the game just after it.
    await tester.tap(find.text('1.e4', findRichText: true));
    expect(analyzed.last.$3, 1);
  });

  testWidgets('an unfinished game with no date shows neither, and the '
      'review\'s counts come under the players', (tester) async {
    saveGame(
      _savedGame
          .replaceFirst('[Date "2026.09.20"]', '[Date "????.??.??"]')
          .replaceFirst('[Result "0-1"]', '[Result "*"]')
          .replaceFirst(' 0-1', ' *'),
    );
    await pumpPane(tester);
    await show(tester, 0);
    expect(find.text('Me (2080) – Rival'), findsOneWidget);
    expect(find.text('0-1 · 2026.09.20'), findsNothing);
    expect(find.textContaining('????'), findsNothing);
    expect(find.text('*'), findsNothing);

    expect(
      w.session.apply(
        (set) => withMined(
          set,
          const [],
          analyzed: analyzedIn(set.preamble),
          mistakes: {
            'lichess_abc': const MistakeCounts(blunders: 1, inaccuracies: 2),
          },
        ),
      ),
      isNull,
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('1 blunder, 2 inaccuracies'), findsOneWidget);
  });

  testWidgets('a game that never reaches the puzzle opens at its start', (
    tester,
  ) async {
    saveGame(_savedGame.replaceFirst(RegExp(r'1\. e4.*'), '1. d4 d5 0-1'));
    await pumpPane(tester);
    await show(tester, 0);
    expect(find.text('1.d4', findRichText: true), findsOneWidget);
    await tester.tap(find.text('Open on analysis board'));
    expect(analyzed.single.$2.mistake, isNull);
    expect(analyzed.single.$3, 0);
  });

  testWidgets('the puzzle\'s move is brought into view, and so is the next '
      'puzzle\'s in its own game', (tester) async {
    tester.view.physicalSize = const Size(420, 260);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // Knights out and back many times, then the game: the puzzle's move is
    // far down the text.
    final shuffles = [
      for (var i = 0; i < 30; i++)
        '${2 * i + 1}. Nf3 Nf6 ${2 * i + 2}. Ng1 Ng8',
    ].join(' ');
    const late = '1. e4 e5 2. Bc4 Nc6 3. Qh5 Nf6 4. Qe2 Nd4 5. Qd1';
    final lateGame = _savedGame.replaceFirst(
      late,
      '$shuffles ${late.replaceAllMapped(RegExp(r'(\d+)\.'), (m) => '${int.parse(m[1]!) + 60}.')}',
    );
    // The second puzzle's game: its move, 1... f6, at the top.
    final earlyGame = [
      '[Event "Rated blitz game"]',
      '[White "Other"]',
      '[Black "Me"]',
      '[Result "*"]',
      '[GameId "lichess_def"]',
      '',
      '1. e4 f6 $shuffles *',
    ].join('\n');
    saveGame('$lateGame\n\n$earlyGame');
    await pumpPane(tester);

    bool inView(Finder move) {
      final viewport = tester.getRect(find.byType(SingleChildScrollView));
      final rect = tester.getRect(move);
      return rect.top >= viewport.top - 1 && rect.bottom <= viewport.bottom + 1;
    }

    await show(tester, 0);
    await tester.pumpAndSettle();
    final qe2 = find.text('64.Qe2??', findRichText: true);
    expect(qe2, findsOneWidget);
    expect(inView(qe2), isTrue, reason: 'scrolled down to it');

    await show(tester, 1);
    await tester.pumpAndSettle();
    final f6 = find.text('f6?', findRichText: true);
    expect(f6, findsOneWidget);
    expect(inView(f6), isTrue, reason: 'scrolled back up to it');
  });
}

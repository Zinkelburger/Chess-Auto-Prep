import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/models/pgn_game_entry.dart';
import 'package:chess_auto_prep/widgets/pgn/pgn_tree_games_list.dart';

const _startFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

PgnGameEntry _game({
  required String white,
  required String black,
  required String pgnMoves,
  int rating = 0,
  String? result,
  String? date,
}) {
  return PgnGameEntry(
    headers: {'White': white, 'Black': black, 'Result': ?result, 'Date': ?date},
    pgnText: '[White "$white"]\n[Black "$black"]\n\n$pgnMoves',
    studyRating: rating,
  );
}

Future<void> _pumpList(
  WidgetTester tester, {
  required List<PgnGameEntry> games,
  required List<int> opened,
  String fen = _startFen,
  double width = 420,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: width,
          height: 400,
          child: PgnTreeGamesList(
            games: games,
            currentFen: fen,
            currentIndex: 0,
            onGameSelected: opened.add,
            onSearch: () {},
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('starts expanded with title and truncated comment-free PV', (
    tester,
  ) async {
    await _pumpList(
      tester,
      games: [
        _game(
          white: 'Carlsen',
          black: 'Nakamura',
          pgnMoves: '1. e4 {best} e5 2. Nf3 Nc6 *',
        ),
        _game(white: 'Kasparov', black: 'Karpov', pgnMoves: '1. d4 d5 *'),
      ],
      opened: [],
    );

    expect(find.text('Carlsen vs Nakamura'), findsOneWidget);
    expect(find.text('Kasparov vs Karpov'), findsOneWidget);
    expect(find.text('Show moves'), findsOneWidget);
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);

    final pv = tester.widget<Text>(find.text('1. e4 e5 2. Nf3 Nc6'));
    expect(pv.maxLines, 1);
    expect(pv.softWrap, isFalse);
    expect(pv.overflow, TextOverflow.ellipsis);
    expect(find.textContaining('{best}'), findsNothing);
    expect(find.text('1. d4 d5'), findsOneWidget);

    // Show moves: the triangle is a bullet, not a preview button.
    expect(find.byTooltip('Preview line'), findsNothing);
    expect(find.byIcon(Icons.play_arrow), findsWidgets);
  });

  testWidgets(
    'completed results stay visible beside long titles with moves hidden',
    (tester) async {
      final opened = <int>[];
      await _pumpList(
        tester,
        width: 260,
        games: [
          for (final result in ['1-0', '0-1', '1/2-1/2'])
            _game(
              white: 'A very long player name',
              black: 'Another long player name',
              date: '2026.09.09',
              result: result,
              pgnMoves: '1. e4 e5 $result',
            ),
          _game(
            white: 'Unfinished',
            black: 'Game',
            result: '*',
            pgnMoves: '1. d4 *',
          ),
        ],
        opened: opened,
      );
      expect(find.text('At this position'), findsNothing);
      await tester.tap(find.text('Show moves'));
      await tester.pump();
      expect(find.text('1. e4 e5'), findsNothing);
      for (final result in ['1-0', '0-1', '1/2-1/2']) {
        final resultText = find.text(result);
        expect(resultText, findsOneWidget);
        expect(tester.getRect(resultText).right, lessThanOrEqualTo(260));
      }
      expect(find.text('*'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('1/2-1/2'));
      await tester.pump();
      expect(opened, [2]);
    },
  );

  testWidgets('tapping an expanded row opens the game', (tester) async {
    final opened = <int>[];
    await _pumpList(
      tester,
      games: [
        _game(white: 'Carlsen', black: 'Nakamura', pgnMoves: '1. e4 e5 *'),
      ],
      opened: opened,
    );

    await tester.tap(find.text('Carlsen vs Nakamura'));
    await tester.pump();
    expect(opened, [0]);
  });

  testWidgets(
    'with show moves off, the arrow previews and the title opens the game',
    (tester) async {
      final opened = <int>[];
      await _pumpList(
        tester,
        games: [
          _game(
            white: 'Carlsen',
            black: 'Nakamura',
            pgnMoves: '1. e4 e5 2. Nf3 Nc6 *',
          ),
        ],
        opened: opened,
      );

      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);
      expect(find.text('1. e4 e5 2. Nf3 Nc6'), findsNothing);

      await tester.tap(find.byTooltip('Preview line'));
      await tester.pump();
      expect(opened, isEmpty);
      expect(find.text('1. e4 e5 2. Nf3 Nc6'), findsOneWidget);

      await tester.tap(find.text('Carlsen vs Nakamura'));
      await tester.pump();
      expect(opened, [0]);
    },
  );
}

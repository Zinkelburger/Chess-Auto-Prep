import 'package:chess_auto_prep/models/repertoire_line.dart';
import 'package:chess_auto_prep/services/repertoire_review_service.dart';
import 'package:chess_auto_prep/widgets/training/training_mistakes_panel.dart';
import 'package:dartchess/dartchess.dart' show Chess;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Attempts implements RepertoireReviewService {
  @override
  Future<List<Map<String, dynamic>>> loadAttempts({
    String? repertoireId,
  }) async => [
    for (final (source, played, correct) in [
      ('a.pgn', 'Bc4', false),
      ('b.pgn', 'Nc3', false),
      ('a.pgn', 'Nf3', true),
    ])
      {
        'repertoireId': source,
        'lineId': 'shared-id',
        'playedSan': played,
        'expectedSan': 'Nf3',
        'correct': correct,
        'fen': 'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2',
        'moveIndex': 2,
        'phase': 'drilling',
        'timestampUtc': DateTime.now().toUtc().toIso8601String(),
      },
  ];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
    'searching a wrong move opens its original chapter and position',
    (tester) async {
      final original = RepertoireLine(
        id: 'shared-id',
        name: 'Opening',
        moves: const ['e4', 'e5', 'Nf3'],
        color: 'white',
        startPosition: Chess.initial,
        fullPgn: '1. e4 e5 2. Nf3 *',
      );
      RepertoireLine? opened;
      int? index;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TrainingMistakesPanel(
              service: _Attempts(),
              sourcePaths: const {'a.pgn', 'b.pgn'},
              lines: [
                original.inSource('a.pgn', 'Chapter A'),
                original.inSource('b.pgn', 'Chapter B'),
              ],
              onClose: () {},
              onRead: (line, at) {
                opened = line;
                index = at;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ListTile), findsNWidgets(2));
      expect(find.textContaining('Practice · just now'), findsNWidgets(2));
      await tester.enterText(find.byType(TextField), 'bc4');
      await tester.pump();
      expect(find.byType(ListTile), findsOneWidget);
      expect(find.textContaining('Book: 2. Nf3'), findsOneWidget);
      expect(find.textContaining('You: 2. Bc4'), findsOneWidget);
      await tester.tap(find.byType(ListTile));
      expect(opened?.sourcePath, 'a.pgn');
      expect(opened?.persistedId, 'shared-id');
      expect(index, 2);
      await tester.enterText(find.byType(TextField), 'not a move');
      await tester.pump();
      expect(find.text('No mistakes match your search.'), findsOneWidget);
    },
  );
}

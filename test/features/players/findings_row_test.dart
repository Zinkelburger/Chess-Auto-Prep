import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/engines/engine_line.dart';
import 'package:chess_auto_prep/features/players/findings_view.dart';
import 'package:chess_auto_prep/features/players/player_games.dart';
import 'package:chess_auto_prep/features/players/player_hunt.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a finding row in the 300 px column says its kind in full', (
    tester,
  ) async {
    final position = PlayerPosition(
      fen: Fen.initial,
      side: Side.white,
      line: const [],
      game: 0,
      ply: 0,
    );
    final finding = PlayerWeakness(position, const Centipawns(26), const [
      'g1f3',
      'b8c6',
      'f1b5',
      'g8f6',
      'e1g1',
      'f8e7',
      'd2d4',
    ], true);
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 300,
              child: FindingRow(
                finding: finding,
                dismissed: false,
                onOpen: () {},
                onToggle: () {},
              ),
            ),
          ),
        ),
      ),
    );
    final title = tester.renderObject<RenderParagraph>(
      find.text('Strong reply absent from these games'),
    );
    expect(title.didExceedMaxLines, isFalse);
    expect(find.text('+0.26'), findsOneWidget);
    expect(find.text('0 games · 1. Nf3 Nc6'), findsOneWidget);
  });
}

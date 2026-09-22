import 'package:chess_auto_prep/app/runtime_settings.dart';
import 'package:provider/provider.dart';
import 'package:chess_auto_prep/features/settings/controllers/board_display_settings.dart';
import 'package:chess_auto_prep/features/settings/models/board_display_configuration.dart';
import 'package:chess_auto_prep/features/settings/widgets/san_display.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('figurineSan', () {
    test('swaps the piece letter and a promotion piece, nothing else', () {
      expect(figurineSan('Nf3'), '♘f3');
      expect(figurineSan('Qxf7#'), '♕xf7#');
      expect(figurineSan('R1e1'), '♖1e1');
      expect(figurineSan('Kxe2'), '♔xe2');
      expect(figurineSan('Bb5+'), '♗b5+');
      expect(figurineSan('exd8=Q+'), 'exd8=♕+');
      expect(figurineSan('b1=N'), 'b1=♘');
    });

    test('leaves pawn moves, castling and non-moves alone', () {
      expect(figurineSan('e4'), 'e4');
      expect(figurineSan('exd5'), 'exd5');
      expect(figurineSan('O-O'), 'O-O');
      expect(figurineSan('O-O-O'), 'O-O-O');
      expect(figurineSan(''), '');
      expect(figurineSan('1-0'), '1-0');
    });
  });

  group('BoardDisplaySettings', () {
    test('defaults match lila: coordinates inside, letters', () {
      final settings = RuntimeSettings.preferences().display;
      expect(settings.coordinates, BoardCoordinates.inside);
      expect(settings.showLegalMoves, isFalse);
      expect(settings.pieceNotation, PieceNotation.letters);
    });

    test(
      'changes notify and persist, and a fresh load reads them back',
      () async {
        final settings = RuntimeSettings.preferences().display;
        var notified = 0;
        settings.addListener(() => notified++);

        await settings.setShowLegalMoves(true);
        await settings.setCoordinates(BoardCoordinates.outside);
        await settings.setPieceNotation(PieceNotation.figurines);
        await settings.setPieceNotation(PieceNotation.figurines); // no-op
        expect(notified, greaterThanOrEqualTo(3));

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('display.legal_moves'), isTrue);
        expect(prefs.getString('display.board_coordinates'), 'outside');
        expect(prefs.getString('display.piece_notation'), 'figurines');

        final reloaded = RuntimeSettings.preferences().display;
        await reloaded.ensureLoaded();
        expect(reloaded.showLegalMoves, isTrue);
        expect(reloaded.coordinates, BoardCoordinates.outside);
        expect(reloaded.pieceNotation, PieceNotation.figurines);
      },
    );

    test('an unknown stored value falls back to the default', () async {
      SharedPreferences.setMockInitialValues({
        'display.board_coordinates': 'sideways',
        'display.piece_notation': 'emoji',
      });
      final settings = RuntimeSettings.preferences().display;
      await settings.ensureLoaded();
      expect(settings.coordinates, BoardCoordinates.inside);
      expect(settings.pieceNotation, PieceNotation.letters);
    });

    test('reset commits defaults using the existing keys', () async {
      final settings = RuntimeSettings.preferences().display;
      await settings.setShowLegalMoves(true);
      await settings.setCoordinates(BoardCoordinates.everySquare);
      await settings.resetToDefaults();
      expect(settings.showLegalMoves, isFalse);
      expect(settings.coordinates, BoardCoordinates.inside);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('display.board_coordinates'), 'inside');
    });
  });

  group('BoardDisplaySettings.of', () {
    testWidgets('without a scope it has immutable preview defaults', (
      tester,
    ) async {
      late BoardDisplayConfiguration seen;
      await tester.pumpWidget(
        Builder(
          builder: (context) {
            seen =
                (context.watch<BoardDisplaySettings?>()?.committed ??
                BoardDisplayConfiguration());
            return const SizedBox();
          },
        ),
      );
      expect(seen, BoardDisplayConfiguration());
    });

    testWidgets('a scoped change redraws a move list in place', (tester) async {
      final settings = RuntimeSettings.preferences().display;
      await tester.pumpWidget(
        ChangeNotifierProvider<BoardDisplaySettings>.value(
          value: settings,
          child: MaterialApp(
            home: Builder(
              builder: (context) => Text(displaySan(context, 'Nf3')),
            ),
          ),
        ),
      );
      expect(find.text('Nf3'), findsOneWidget);

      await settings.setPieceNotation(PieceNotation.figurines);
      await tester.pump();
      expect(find.text('♘f3'), findsOneWidget);
      expect(find.text('Nf3'), findsNothing);

      await settings.setPieceNotation(PieceNotation.letters);
      await tester.pump();
      expect(find.text('Nf3'), findsOneWidget);
    });
  });
}

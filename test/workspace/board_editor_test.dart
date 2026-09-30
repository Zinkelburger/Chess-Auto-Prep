import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:chess_auto_prep/workspace/board_editor.dart';
import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Fen? answered;
  var closed = false;

  Future<void> open(WidgetTester tester, {Fen initial = Fen.initial}) async {
    answered = null;
    closed = false;
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              answered = await showBoardEditor(context, initial: initial);
              closed = true;
            },
            child: const Text('Ask'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Ask'));
    await tester.pumpAndSettle();
  }

  Map<Square, Piece> pieces(WidgetTester tester) =>
      tester.widget<ChessboardEditor>(find.byType(ChessboardEditor)).pieces;

  /// The centre of [square] on the editor's board, White below.
  Offset at(WidgetTester tester, String square) {
    final corner = tester.getTopLeft(find.byType(ChessboardEditor));
    const side = editorBoardSize / 8;
    final file = square.codeUnitAt(0) - 'a'.codeUnitAt(0);
    final rank = int.parse(square[1]) - 1;
    return corner +
        Offset(file * side + side / 2, (7 - rank) * side + side / 2);
  }

  FilledButton use(WidgetTester tester) => tester.widget<FilledButton>(
    find.widgetWithText(FilledButton, 'Use this position'),
  );

  testWidgets('a clicked spare piece paints the squares pressed, a right-'
      'click empties one, and the position is used once it is legal', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.text('Clear board'));
    await tester.pump();
    expect(find.text('The board is empty.'), findsOneWidget);
    expect(use(tester).onPressed, isNull);

    await tester.tap(find.byTooltip('White king'));
    await tester.pump();
    await tester.tapAt(at(tester, 'e1'));
    await tester.pump();
    expect(find.text('Each side needs exactly one king.'), findsOneWidget);
    await tester.tap(find.byTooltip('Black king'));
    await tester.pump();
    await tester.tapAt(at(tester, 'e8'));
    await tester.tapAt(at(tester, 'd8'));
    await tester.pump();
    expect(pieces(tester), hasLength(3));

    await tester.tapAt(at(tester, 'e8'), buttons: kSecondaryButton);
    await tester.pump();
    expect(pieces(tester)[Square.e8], isNull);
    expect(find.text('The board is empty.'), findsNothing);

    await tester.tap(find.text('Black to play'));
    await tester.pump();
    expect(find.text('3k4/8/8/8/8/8/8/4K3 b - - 0 1'), findsOneWidget);
    await tester.tap(find.text('Use this position'));
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(answered, const Fen('3k4/8/8/8/8/8/8/4K3 b - - 0 1'));
  });

  testWidgets('a spare piece dragged onto the board lands where it is '
      'dropped and leaves the pointer in hand', (tester) async {
    await open(tester);
    final queen = tester.getCenter(find.byTooltip('White queen'));
    final gesture = await tester.startGesture(queen);
    await gesture.moveBy(const Offset(0, -20));
    await gesture.moveTo(at(tester, 'e4'));
    await gesture.up();
    await tester.pump();
    expect(
      pieces(tester)[Square.e4],
      const Piece(color: Side.white, role: Role.queen),
    );
    // Pressing the board with the pointer paints nothing.
    await tester.tapAt(at(tester, 'e5'));
    await tester.pump();
    expect(pieces(tester)[Square.e5], isNull);
  });

  testWidgets('the FEN typed sets the board; text that is no FEN says so '
      'and keeps the board', (tester) async {
    await open(tester);
    final fen = find.widgetWithText(TextField, 'FEN');
    await tester.enterText(fen, '8/8/4k3/8/8/4K3/4R3/8 w - - 0 1');
    await tester.pump();
    expect(pieces(tester), hasLength(3));
    expect(use(tester).onPressed, isNotNull);
    await tester.enterText(fen, '8/8/4k3');
    await tester.pump();
    expect(find.text('Could not read that FEN.'), findsOneWidget);
    expect(pieces(tester), hasLength(3));
    expect(use(tester).onPressed, isNull);
    // A board dartchess's parser throws a bare ArgumentError on.
    await tester.enterText(fen, 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/.NBQKBNR');
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Could not read that FEN.'), findsOneWidget);
    expect(pieces(tester), hasLength(3));
  });

  testWidgets('en passant is offered only where a pawn can take, so the FEN '
      'is the one the same position reached by moves has', (tester) async {
    await open(tester);
    final fen = find.widgetWithText(TextField, 'FEN');
    // After 1.e4 no black pawn can take on e3: moves write `-` there.
    await tester.enterText(
      fen,
      'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1',
    );
    await tester.pump();
    expect(find.widgetWithText(ChoiceChip, 'e3'), findsNothing);
    await tester.tap(find.text('Use this position'));
    await tester.pumpAndSettle();
    expect(
      answered,
      const Fen('rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1'),
    );
  });

  testWidgets('castling is offered only while king and rook are at home', (
    tester,
  ) async {
    await open(tester);
    Checkbox box(String rook) =>
        tester.widget<Checkbox>(find.byKey(ValueKey('castling $rook')));
    expect(box('h1').value, isTrue);
    // Either strip's bin is the same tool.
    await tester.tap(find.byTooltip('Erase pieces').first);
    await tester.pump();
    await tester.tapAt(at(tester, 'h1'));
    await tester.pump();
    expect(box('h1').value, isFalse);
    expect(box('h1').onChanged, isNull);
    expect(box('a1').onChanged, isNotNull);
    await tester.tap(find.byKey(const ValueKey('castling a8')));
    await tester.pump();
    expect(
      find.text('rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBN1 w Qk - 0 1'),
      findsOneWidget,
    );
  });
}

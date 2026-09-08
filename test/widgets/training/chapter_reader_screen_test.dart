import 'package:chess_auto_prep/models/repertoire_line.dart';
import 'package:chess_auto_prep/widgets/chess_board_widget.dart';
import 'package:chess_auto_prep/widgets/training/chapter_reader_screen.dart';
import 'package:dartchess/dartchess.dart' show Chess, Position;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

RepertoireLine _line(String id, String name, String movetext) {
  final moves = movetext
      .replaceAll(RegExp(r'\{[^}]*\}'), '')
      .split(RegExp(r'\s+'))
      .where((t) => t.isNotEmpty && !RegExp(r'^\d+\.').hasMatch(t))
      .toList();
  return RepertoireLine(
    id: id,
    name: name,
    moves: moves,
    color: 'black',
    startPosition: Chess.initial,
    fullPgn:
        '[Event "Test"]\n[White "Chapter"]\n[Black "$name"]\n\n$movetext *',
  );
}

final _lines = [
  _line('a', 'Classical 3.Nc3', '1. e4 e6 2. d4 d5 3. Nc3 Nf6 {A note.}'),
  _line('b', 'Tarrasch 3.Nd2', '1. e4 e6 2. d4 d5 3. Nd2 c5'),
];

Future<void> _pump(
  WidgetTester tester, {
  void Function(RepertoireLine)? onTrainLine,
  List<RepertoireLine>? lines,
}) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    MaterialApp(
      home: ChapterReaderScreen(
        repertoireName: 'French',
        chapterTitle: 'Chapter 1',
        lines: lines ?? _lines,
        onTrainLine: onTrainLine,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'null-move overview previews a legal line and returns without changing the course',
    (tester) async {
      final line = _line(
        'intro',
        'Introduction',
        '1.e4 {Welcome.} (1.e4 {in one course.}) 1... -- '
            '{Outline [--] • 1... e4 1.e4 c5 We play 2.Nf3 d6 3.d4. '
            '[--] • The **French** starts 1.e4 e6.}',
      );
      final original = line.fullPgn;
      await _pump(tester, lines: [line]);
      expect(find.textContaining('[--]', findRichText: true), findsNothing);
      expect(
        find.textContaining('**French**', findRichText: true),
        findsNothing,
      );
      expect(find.textContaining('1... e4', findRichText: true), findsNothing);
      expect(find.byTooltip('Collapse variation: 1. e4'), findsNothing);
      final before = tester
          .widget<ChessBoardWidget>(find.byType(ChessBoardWidget))
          .position
          .fen;
      await tester.tap(find.text('2.Nf3'));
      await tester.pumpAndSettle();
      Position expected = Chess.initial;
      for (final san in ['e4', 'c5', 'Nf3']) {
        expected = expected.play(expected.parseSan(san)!);
      }
      expect(
        tester
            .widget<ChessBoardWidget>(find.byType(ChessBoardWidget))
            .position
            .fen,
        expected.fen,
      );
      expect(find.text('Comment preview'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expected = expected.play(expected.parseSan('d6')!);
      expect(
        tester
            .widget<ChessBoardWidget>(find.byType(ChessBoardWidget))
            .position
            .fen,
        expected.fen,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(ChapterReaderScreen), findsOneWidget);
      expect(
        tester
            .widget<ChessBoardWidget>(find.byType(ChessBoardWidget))
            .position
            .fen,
        before,
      );
      expect(line.fullPgn, original);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('shows every line of the chapter on one page', (tester) async {
    await _pump(tester);
    expect(find.text('French ▸ Chapter 1'), findsOneWidget);
    expect(find.text('Classical 3.Nc3'), findsWidgets);
    expect(find.text('Tarrasch 3.Nd2'), findsOneWidget);
    expect(find.textContaining('A note', findRichText: true), findsWidgets);
    expect(find.text('Line 1 of 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('→ past the end of a line rolls into the next one', (
    tester,
  ) async {
    await _pump(tester);
    for (var i = 0; i < 6; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
    }
    expect(find.text('Line 1 of 2'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.text('Line 2 of 2'), findsOneWidget);
    // ← at the start of a line goes back to the end of the previous one.
    for (var i = 0; i < 5; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
    }
    expect(find.text('Line 2 of 2'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(find.text('Line 1 of 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('↓ jumps to the next line', (tester) async {
    await _pump(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(find.text('Line 2 of 2'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(find.text('Line 1 of 2'), findsOneWidget);
  });

  testWidgets('Train this line closes the reader and hands the line off', (
    tester,
  ) async {
    RepertoireLine? trained;
    await _pump(tester, onTrainLine: (line) => trained = line);
    await tester.tap(find.text('Train this line'));
    await tester.pumpAndSettle();
    expect(trained?.id, 'a');
    expect(find.byType(ChapterReaderScreen), findsNothing);
  });
}

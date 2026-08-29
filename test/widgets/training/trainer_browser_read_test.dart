import 'package:chess_auto_prep/models/repertoire_line.dart';
import 'package:chess_auto_prep/widgets/training/trainer_browser.dart';
import 'package:dartchess/dartchess.dart' show Chess;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

RepertoireLine _line(String id, String chapter) => RepertoireLine(
  id: id,
  name: 'Line $id',
  moves: const ['e4', 'e6'],
  color: 'black',
  startPosition: Chess.initial,
  fullPgn: '1. e4 e6 *',
  chapter: chapter,
);

Future<void> _pump(
  WidgetTester tester, {
  required String? activeChapter,
  required void Function(List<RepertoireLine>) onReadLines,
}) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: TrainerBrowser(
          title: 'French',
          lines: [_line('a', 'One'), _line('b', 'One'), _line('c', 'Two')],
          reviewMap: const {},
          chapterOf: (line) => line.chapter,
          activeChapter: activeChapter,
          ungroupedChapter: '__ungrouped__',
          onTrainLine: (_) {},
          onReadLines: onReadLines,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Read opens the open chapter\'s lines', (tester) async {
    List<RepertoireLine>? read;
    await _pump(tester, activeChapter: 'One', onReadLines: (l) => read = l);
    await tester.tap(find.text('Read'));
    await tester.pump();
    expect(read?.map((l) => l.id), ['a', 'b']);
  });

  testWidgets('no Read button on the chapter list', (tester) async {
    await _pump(tester, activeChapter: null, onReadLines: (_) {});
    expect(find.text('Read'), findsNothing);
  });
}

import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'package:chess_auto_prep/models/repertoire_line.dart';
import 'package:chess_auto_prep/widgets/training/trainer_browser.dart';
import 'package:dartchess/dartchess.dart' show Chess;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../support/trainer_browser_session.dart';

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
  final session = await trainerBrowserSession(
    name: 'French',
    lines: [_line('a', 'One'), _line('b', 'One'), _line('c', 'Two')],
    activeChapter: activeChapter,
  );
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: TrainerBrowser(session: session, onReadLines: onReadLines),
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

  testWidgets('Read opens all lines without requiring a chapter', (
    tester,
  ) async {
    List<RepertoireLine>? read;
    await _pump(
      tester,
      activeChapter: null,
      onReadLines: (lines) => read = lines,
    );
    await tester.tap(find.text('Read'));
    expect(read?.map((line) => line.id), ['a', 'b', 'c']);
  });
}

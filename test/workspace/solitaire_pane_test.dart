import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:chess_auto_prep/workspace/engine_analysis.dart';
import 'package:chess_auto_prep/workspace/move_tree_view.dart';
import 'package:chess_auto_prep/workspace/solitaire.dart';
import 'package:chess_auto_prep/workspace/solitaire_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/session_fixture.dart';

void main() {
  testWidgets('progress conceals answers; final record copies attempts and '
      'offers read-only board review', (tester) async {
    const pgn = '''
[Event "Practice"]
[Result "*"]

1. e4 {Secret answer: Nf3} e5 2. Nf3 *
''';
    final fixture = await openSession(pgn);
    final analysis = EngineAnalysis(
      fixture.session,
      () async => const StartFailed('unused'),
    );
    final solitaire = Solitaire(fixture.session, analysis);
    addTearDown(fixture.dispose);
    addTearDown(analysis.dispose);
    addTearDown(solitaire.dispose);
    await tester.binding.setSurfaceSize(const Size(650, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    solitaire.start();
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: Column(
            children: [
              Expanded(
                child: ListenableBuilder(
                  listenable: solitaire,
                  builder: (context, _) => MoveTreeView(
                    session: fixture.session,
                    preview: (
                      tree: solitaire.record!,
                      onRead: solitaire.inspect,
                    ),
                  ),
                ),
              ),
              Expanded(child: SolitairePane(solitaire: solitaire)),
            ],
          ),
        ),
      ),
    );
    expect(find.text('Make your first move'), findsOneWidget);
    expect(find.textContaining('Secret answer'), findsNothing);
    solitaire.play('g2g4');
    solitaire.play('e2e4');
    await tester.pump(Solitaire.replyDelay);
    await tester.pumpAndSettle();
    expect(find.text('1. g4'), findsOneWidget);
    expect(find.textContaining('Secret answer'), findsNothing);
    expect(find.textContaining('Nf3'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('solitaire-hint')));
    await tester.pumpAndSettle();
    expect(find.text('Move your knight.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('solitaire-reveal')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('solitaire-copy-pgn')));
    await tester.pumpAndSettle();
    expect(copied, contains('1. g4'));
    expect(copied, contains('Mistake'));
    expect(copied, contains('Hint used'));
    expect(copied, contains('Secret answer'));
    await tester.ensureVisible(find.text('1. g4'));
    await tester.tap(find.text('1. g4'));
    await tester.pumpAndSettle();
    expect(fixture.session.boardFen, solitaire.record!.children[1].fen);
    await tester.longPress(find.text('1. g4'));
    await tester.pumpAndSettle();
    expect(find.text('Delete from here'), findsNothing);
    expect(fixture.onDisk, pgn);
    expect(tester.takeException(), isNull);
  });
}

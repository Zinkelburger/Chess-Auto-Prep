import 'package:chess_auto_prep/ui/move_notation.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:chess_auto_prep/workspace/move_tree_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/session_fixture.dart';

const _line = '''
// Color: White

[Event "Knights"]
[Result "*"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. O-O *
''';

void main() {
  group('figurineSan', () {
    test('draws piece letters of moves as figurines', () {
      expect(figurineSan('Nf3'), '♘f3');
      expect(figurineSan('Qxe7+'), '♕xe7+');
      expect(figurineSan('Nbd7'), '♘bd7');
      expect(figurineSan('R1e2'), '♖1e2');
      expect(figurineSan('exd8=Q#'), 'exd8=♕#');
      expect(figurineSan('N@f3'), '♘@f3');
    });

    test('leaves castling, pawns and prose alone', () {
      expect(figurineSan('O-O-O'), 'O-O-O');
      expect(figurineSan('e4'), 'e4');
      expect(
        figurineSan('Book ends after 12...Bd7'),
        'Book ends after 12...♗d7',
      );
      expect(figurineSan('Bad Knight, Queen side'), 'Bad Knight, Queen side');
      expect(figurineSan('1.e4 e5 2.Nf3 Nc6'), '1.e4 e5 2.♘f3 ♘c6');
    });
  });

  testWidgets('the move list follows the notation the window is set to', (
    tester,
  ) async {
    final fixture = await openSession(_line);
    addTearDown(fixture.dispose);
    final figurines = ValueNotifier(false);
    addTearDown(figurines.dispose);
    await tester.binding.setSurfaceSize(const Size(400, 600));
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: ValueListenableBuilder(
          valueListenable: figurines,
          builder: (context, on, child) =>
              MoveNotation(figurines: on, child: child!),
          child: Scaffold(body: MoveTreeView(session: fixture.session)),
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('Nf3', findRichText: true), findsOneWidget);
    expect(find.textContaining('♘', findRichText: true), findsNothing);

    figurines.value = true;
    await tester.pump();
    expect(find.textContaining('♘f3', findRichText: true), findsOneWidget);
    expect(find.textContaining('♘c6', findRichText: true), findsOneWidget);
    expect(find.textContaining('♗b5', findRichText: true), findsOneWidget);
    expect(find.textContaining('O-O', findRichText: true), findsOneWidget);
    expect(find.textContaining('Nf3', findRichText: true), findsNothing);
    // The document keeps its letters.
    expect(fixture.session.chapter!.tree.children.single.san, 'e4');
    expect(
      fixture
          .session
          .chapter!
          .tree
          .children
          .single
          .children
          .single
          .children
          .single
          .san,
      'Nf3',
    );
  });
}

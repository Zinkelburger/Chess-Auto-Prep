import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:chess_auto_prep/v2/workspace/repertoire_shelf.dart';
import 'package:chess_auto_prep/v2/workspace/repertoire_tree.dart';
import 'package:chess_auto_prep/v2/workspace/tree_pane.dart';
import 'package:chessground/chessground.dart' show StaticChessboard;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_files.dart';
import '../support/session_fixture.dart';

/// The chapter on the board: two lines of the Italian.
const italian = '''
// Color: White

[Event "Italian"]
[Result "*"]

1. e4 e5 2. Nf3 Nc6 3. Bc4 Bc5 4. c3 *

[Event "Italian"]
[Result "*"]

1. e4 e5 2. Nf3 Nc6 3. Bc4 Nf6 4. d3 *
''';

void main() {
  late SessionFixture fixture;

  setUp(() async {
    fixture = await openSession(italian, name: 'Italian', repertoire: 'e4');
  });

  tearDown(() => fixture.dispose());

  /// The tree is made inside the test body, so the reads it starts run
  /// while the test pumps.
  Future<void> show(WidgetTester tester) async {
    final tree = RepertoireTree(
      session: fixture.session,
      shelf: RepertoireShelf(
        files: ScriptedFiles(
          listing: Repertoires([
            folder('e4', ['Italian']),
          ]),
        ),
        documents: fixture.store,
      ),
    );
    addTearDown(tree.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 600,
            height: 400,
            child: TreePane(session: fixture.session, tree: tree),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the floated board goes when the rows change under the '
      'pointer, and the row now there floats its own', (tester) async {
    await show(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer();
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('e4')));
    await tester.pump(previewDelay);
    StaticChessboard board() =>
        tester.widget<StaticChessboard>(find.byType(StaticChessboard));
    expect(board().lastMove?.uci, 'e2e4');
    fixture.session.forward();
    await tester.pump();
    expect(find.byType(StaticChessboard), findsNothing);
    await tester.pump(previewDelay);
    expect(board().lastMove?.uci, 'e7e5');
  });
}

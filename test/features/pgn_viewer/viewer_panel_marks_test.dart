// The viewer's list marks the game on the board: its own row, or a study
// chapter's row when the chapter is that one game, never a heading over
// several; and chapters opened by hand in one file start shut in the next.
import 'package:chess_auto_prep/features/pgn_viewer/pgn_viewer_panel.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/ui/list_row.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_store.dart';
import '../../support/viewer_fixture.dart';

const _course = '''
[Event "Course"]
[White "Italian"]
[Black "Main line"]
[Result "*"]

1. e4 e5 2. Nf3 Nc6 3. Bc4 Bc5 *

[Event "Course"]
[White "Italian"]
[Black "Two Knights"]
[Result "*"]

1. e4 e5 2. Nf3 Nc6 3. Bc4 Nf6 *

[Event "Course"]
[White "Sicilian"]
[Black "Najdorf"]
[Result "*"]

1. e4 c5 2. Nf3 d6 *

[Event "Course"]
[White "Sicilian"]
[Black "Dragon"]
[Result "*"]

1. e4 c5 2. Nf3 g6 *
''';

const _study = '''
[Event "My study: Chapter one"]
[ChapterName "Chapter one"]
[Result "*"]

1. d4 d5 *

[Event "My study: Chapter two"]
[ChapterName "Chapter two"]
[Result "*"]

1. c4 e5 *
''';

void main() {
  late ViewerFixture fixture;
  tearDown(() => fixture.dispose());

  Future<void> show(WidgetTester tester, String text) async {
    fixture = await viewerOver(text);
    await fixture.open();
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 300,
            child: PgnViewerPanel(
              viewer: fixture.viewer,
              filter: fixture.filter,
              onOpen: (_) {},
              onBrowse: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  bool marked(WidgetTester tester, String text) => tester
      .widget<ListRow>(
        find.ancestor(of: find.text(text), matching: find.byType(ListRow)),
      )
      .selected;

  testWidgets('the open game\'s row is marked, not the heading over it', (
    tester,
  ) async {
    await show(tester, _course);
    expect(marked(tester, 'Main line'), isTrue);
    expect(marked(tester, 'Two Knights'), isFalse);
    expect(marked(tester, 'Italian'), isFalse);
  });

  testWidgets('a study chapter of one game is marked as that game', (
    tester,
  ) async {
    await show(tester, _study);
    expect(marked(tester, 'Chapter one'), isTrue);
    expect(marked(tester, 'Chapter two'), isFalse);
  });

  testWidgets('chapters opened by hand start shut in the next file', (
    tester,
  ) async {
    await show(tester, _course);
    await tester.tap(find.text('Sicilian'));
    await tester.pumpAndSettle();
    expect(find.text('Najdorf'), findsOneWidget);
    final other = collectionRef('other');
    fixture.store.documents[other] = Opened(_course, scriptedRevision(_course));
    await fixture.session.open(other);
    await fixture.viewer.opened(other);
    await tester.pumpAndSettle();
    expect(find.text('Najdorf'), findsNothing);
  });
}

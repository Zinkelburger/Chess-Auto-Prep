import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:chess_auto_prep/v2/workspace/document_session.dart';
import 'package:chess_auto_prep/v2/workspace/reading_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';
import '../support/session_fixture.dart';
import '../support/study_fixture.dart';
import '../support/viewer_fixture.dart';

/// Two games from 1. e4, the second stopping at a move nobody can play.
const _partial =
    '// Color: White\n'
    '\n'
    '[Event "A"]\n'
    '[Result "*"]\n'
    '\n'
    '1. e4 e5 *\n'
    '\n'
    '[Event "B"]\n'
    '[Result "*"]\n'
    '\n'
    '1. e4 e5 2. Ke3 Nf6 *\n';

void main() {
  late SessionFixture fixture;

  setUp(() async => fixture = await openSession(blackChapter));

  tearDown(() => fixture.dispose());

  Future<void> pump(WidgetTester tester, DocumentSession session) async {
    await tester.binding.setSurfaceSize(const Size(500, 600));
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(body: ReadingHeader(session: session)),
      ),
    );
    await tester.pump();
  }

  testWidgets('shows which side the chapter is for and changes it', (
    tester,
  ) async {
    await pump(tester, fixture.session);
    expect(find.text('Black'), findsOneWidget);
    await tester.tap(find.text('White'));
    await tester.pumpAndSettle();
    expect(fixture.onDisk, startsWith('// Color: White\n'));
    expect(fixture.session.orientation.name, 'white');
  });

  testWidgets('names the chapter and its lines, and nothing about saving', (
    tester,
  ) async {
    await pump(tester, fixture.session);
    expect(find.text('Main'), findsOneWidget);
    expect(find.text('2 lines, 1 from another position'), findsOneWidget);
    expect(find.text('Saved'), findsNothing);
    expect(find.byType(IconButton), findsNothing);
  });

  testWidgets('says how many lines cannot be edited here', (tester) async {
    // The second game stops at a move that is not legal, so it keeps its
    // own bytes; the user hears that before they try to edit it.
    final other = await openSession(_partial);
    addTearDown(other.dispose);
    await pump(tester, other.session);
    expect(find.text('2 lines, 1 cannot be edited here'), findsOneWidget);
  });

  testWidgets('says when a game could not be read at all', (tester) async {
    final other = await openSession(unreadableGameChapter);
    addTearDown(other.dispose);
    await pump(tester, other.session);
    expect(find.text('1 line, 1 could not be read'), findsOneWidget);
  });

  testWidgets('a study chapter is not offered a repertoire playing side', (
    tester,
  ) async {
    final study = await openStudy(twoChapterStudy);
    addTearDown(study.dispose);
    await pump(tester, study.session);
    // Its board faces the way its own Orientation tag says, which the study
    // list changes; the `// Color:` buttons belong to a repertoire chapter.
    expect(find.text('White'), findsNothing);
    expect(find.text('Black'), findsNothing);
  });

  testWidgets('a viewed game is headed by its players, then where', (
    tester,
  ) async {
    final viewed = await viewerOver(threeGameFile);
    addTearDown(viewed.dispose);
    await viewed.open();
    await pump(tester, viewed.session);
    expect(find.text('Carlsen, Magnus – Nakamura, Hikaru'), findsOneWidget);
    expect(find.text('1-0 · Tata Steel · 2024'), findsOneWidget);
  });
}

/// A chapter of two games, the first of which names a position nothing can
/// read.
const unreadableGameChapter = '''
// Color: White

[Event "Broken"]
[FEN "not a fen"]
[Result "*"]

1. e4 *

[Event "Good"]
[Result "*"]

1. d4 d5 *
''';

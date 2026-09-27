import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart' show Opened;
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:chess_auto_prep/v2/workspace/comment_field.dart';
import 'package:chess_auto_prep/v2/workspace/session_results.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';
import '../support/scripted_store.dart';
import '../support/session_fixture.dart';

void main() {
  late SessionFixture fixture;
  final sicilian = NodePath.of([0]);

  setUp(() async => fixture = await openSession(blackChapter));

  tearDown(() => fixture.dispose());

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: Column(
            children: [
              CommentField(session: fixture.session),
              // Something else to give the focus to, as the move list does.
              const TextField(key: Key('elsewhere')),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> blur(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('elsewhere')));
    await tester.pump();
  }

  testWidgets('shows the words of the move under the cursor, not its tokens', (
    tester,
  ) async {
    fixture.session.goTo(sicilian);
    await pump(tester);
    expect(find.text('The Sicilian'), findsOneWidget);
    expect(find.textContaining('[%eval'), findsNothing);
  });

  testWidgets('what is typed is written when the field loses the focus', (
    tester,
  ) async {
    fixture.session.goTo(sicilian);
    await pump(tester);
    await tester.enterText(find.byType(TextField).first, 'Our Sicilian');
    await blur(tester);
    await tester.pumpAndSettle();
    expect(fixture.onDisk, contains('{Our Sicilian [%eval 0.30]}'));
  });

  testWidgets('words typed are written when the panel goes away', (
    tester,
  ) async {
    fixture.session.goTo(sicilian);
    await pump(tester);
    await tester.enterText(find.byType(TextField).first, 'Our Sicilian');
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox())),
    );
    await tester.pumpAndSettle();
    expect(fixture.session.commentAt(sicilian), 'Our Sicilian [%eval 0.30]');
    expect(fixture.onDisk, contains('{Our Sicilian [%eval 0.30]}'));
  });

  testWidgets('the lines the user broke stay broken', (tester) async {
    fixture.session.goTo(sicilian);
    await pump(tester);
    await tester.enterText(find.byType(TextField).first, 'One\nTwo');
    await blur(tester);
    await tester.pumpAndSettle();
    final field = tester.widget<EditableText>(find.byType(EditableText).first);
    expect(field.controller.text, 'One\nTwo');
    expect(fixture.session.commentAt(sicilian), 'One\nTwo [%eval 0.30]');
  });

  testWidgets('the words follow the cursor', (tester) async {
    await pump(tester);
    expect(find.text('The Sicilian'), findsNothing);
    fixture.session.goTo(sicilian);
    await tester.pump();
    expect(find.text('The Sicilian'), findsOneWidget);
    fixture.session.goTo(NodePath.of([0, 1])); // 2. Nc3 {Closed}
    await tester.pump();
    expect(find.text('Closed'), findsOneWidget);
  });

  testWidgets('words typed under one move do not land on another', (
    tester,
  ) async {
    fixture.session.goTo(sicilian);
    await pump(tester);
    await tester.enterText(find.byType(TextField).first, 'Mine');
    fixture.session.goTo(NodePath.of([0, 1]));
    await tester.pump();
    await blur(tester);
    await tester.pumpAndSettle();
    expect(fixture.session.commentAt(sicilian), 'Mine [%eval 0.30]');
    expect(fixture.session.commentAt(NodePath.of([0, 1])), 'Closed');
  });

  testWidgets('a note the session refuses stays in the field', (tester) async {
    fixture.session.goTo(sicilian);
    await pump(tester);
    await tester.enterText(find.byType(TextField).first, 'a } b');
    await blur(tester);
    await tester.pumpAndSettle();
    expect(fixture.session.refusedEdit, isA<WordsRefused>());
    final field = tester.widget<EditableText>(find.byType(EditableText).first);
    expect(field.controller.text, 'a } b', reason: 'to be put right');
    // Nor does the next thing the session says take them away.
    fixture.session.flip();
    await tester.pump();
    expect(field.controller.text, 'a } b');
    expect(fixture.onDisk, blackChapter);
  });

  testWidgets('a note refused as the cursor moves on is asked for once, and '
      'the field follows the cursor', (tester) async {
    fixture.session.goTo(sicilian);
    await pump(tester);
    await tester.enterText(find.byType(TextField).first, 'a } b');
    fixture.session.goTo(NodePath.of([0, 1])); // 2. Nc3 {Closed}
    await tester.pump();
    expect(fixture.session.refusedEdit, isA<WordsRefused>());
    expect(find.text('Closed'), findsOneWidget);
    expect(fixture.onDisk, blackChapter);
  });

  group('when another document goes up while words are in the field', () {
    Future<SessionFixture> gamesOf(WidgetTester tester, String text) async {
      final games = await openSession(text, name: 'Games');
      addTearDown(games.dispose);
      await games.session.open(games.ref, game: 0);
      games.session.goTo(NodePath.of([0]));
      await tester.pumpWidget(
        MaterialApp(
          theme: darkTheme(),
          home: Scaffold(body: CommentField(session: games.session)),
        ),
      );
      await tester.pump();
      return games;
    }

    testWidgets('they go into the game they were typed for', (tester) async {
      final games = await gamesOf(tester, _twoGames);
      await tester.enterText(find.byType(TextField).first, 'for the first');
      games.session.showGame(1); // a viewer moving on; the field has focus
      await tester.pumpAndSettle();
      expect(games.onDisk, contains('1. e4 {for the first} e5 *'));
      expect(games.onDisk, contains('1. d4 d5 *'));
      final field = tester.widget<EditableText>(find.byType(EditableText));
      expect(
        field.controller.text,
        isEmpty,
        reason: 'the second game has none',
      );
    });

    testWidgets('they go into the file they were typed for', (tester) async {
      final other = chapterRef('KID', 'Other');
      fixture.store.documents[other] = Opened(
        whiteChapter,
        scriptedRevision(whiteChapter),
      );
      fixture.session.goTo(sicilian);
      await pump(tester);
      await tester.enterText(find.byType(TextField).first, 'Mine');
      await fixture.session.open(other);
      await tester.pumpAndSettle();
      expect(fixture.onDisk, contains('{Mine [%eval 0.30]}'));
      expect(
        (fixture.store.documents[other]! as Opened).text,
        whiteChapter,
        reason: 'nothing typed for one file lands in the next',
      );
    });

    testWidgets('words the one they were typed for would not take never go '
        'into the next', (tester) async {
      final games = await gamesOf(tester, _brokenThenWhole);
      await tester.enterText(find.byType(TextField).first, 'mine');
      games.session.showGame(1);
      await tester.pumpAndSettle();
      expect(games.onDisk, _brokenThenWhole, reason: 'nothing was written');
    });
  });

  testWidgets('with nothing open the field takes no words', (tester) async {
    final empty = await openSession('// Color: White\n');
    addTearDown(empty.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(body: CommentField(session: empty.session)),
      ),
    );
    expect(find.text('About this chapter'), findsOneWidget);
  });

  testWidgets('shows the note the file wrote before the move, read only', (
    tester,
  ) async {
    fixture.dispose();
    fixture = await openSession(introducedChapter);
    // 1. d4, then its variation 1. c4, which the note introduces.
    fixture.session.goTo(NodePath.of([1]));
    await pump(tester);
    expect(find.text('Before this move'), findsOneWidget);
    expect(find.text('A sideline.'), findsOneWidget);
    expect(find.text('[%eval 0.05]'), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller?.text,
      isEmpty,
      reason: 'the field still edits the comment after the move',
    );
  });

  testWidgets('has no such label for a move nothing introduces', (
    tester,
  ) async {
    fixture.session.goTo(sicilian);
    await pump(tester);
    expect(find.text('Before this move'), findsNothing);
  });
}

/// Two games of a file read one at a time, as a viewer or a study reads it.
const _twoGames = '''
[Event "First"]
[Result "*"]

1. e4 e5 *

[Event "Second"]
[Result "*"]

1. d4 d5 *
''';

/// The same, the first stopped by `--`, a null move this reader cannot play:
/// it is not read whole, so no edit may write it.
const _brokenThenWhole = '''
[Event "First"]
[Result "*"]

1. e4 e5 -- 2. Nf3 *

[Event "Second"]
[Result "*"]

1. d4 d5 *
''';

/// A chapter whose variation is introduced by a note written before its
/// first move.
const introducedChapter = '''
// Color: White

[Event "Introduced"]
[Result "*"]

1. d4 ({A sideline. [%eval 0.05]} 1. c4 e5) 1... d5 *
''';

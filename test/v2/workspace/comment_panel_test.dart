import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:chess_auto_prep/v2/workspace/comment_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';
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
              CommentPanel(session: fixture.session),
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

  testWidgets('with nothing open the field takes no words', (tester) async {
    final empty = await openSession('// Color: White\n');
    addTearDown(empty.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(body: CommentPanel(session: empty.session)),
      ),
    );
    expect(find.text('Comment'), findsOneWidget);
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

/// A chapter whose variation is introduced by a note written before its
/// first move.
const introducedChapter = '''
// Color: White

[Event "Introduced"]
[Result "*"]

1. d4 ({A sideline. [%eval 0.05]} 1. c4 e5) 1... d5 *
''';

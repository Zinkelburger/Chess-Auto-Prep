import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:chess_auto_prep/v2/workspace/edit_strip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';
import '../support/session_fixture.dart';

/// The PGN Viewer holds its edits: moves played there are for looking, and
/// reach the file only when the user saves them.
void main() {
  late SessionFixture fixture;

  setUp(() async {
    fixture = await openSession(blackChapter);
    fixture.session.holdsEdits = true;
  });

  tearDown(() => fixture.dispose());

  /// 1... c5 2. Nf3 d6 3. d4 cxd4, then two moves the file does not have.
  void playTwoNewMoves() {
    fixture.session.goTo(NodePath.of([0, 0, 0, 0, 0]));
    fixture.session.playMove('f3d4');
    fixture.session.playMove('g8f6');
  }

  test('a new move is shown but not written', () async {
    playTwoNewMoves();
    expect(fixture.session.currentMove?.san, 'Nf6');
    expect(fixture.session.hasHeldEdits, isTrue);
    await pumpEventQueue();
    expect(fixture.store.requestedSaves, isEmpty);
    expect(fixture.onDisk, blackChapter);
  });

  test('saving writes every held edit at once', () async {
    playTwoNewMoves();
    fixture.session.keepHeld();
    await pumpEventQueue();
    expect(fixture.session.hasHeldEdits, isFalse);
    expect(fixture.store.requestedSaves, hasLength(1));
    expect(fixture.onDisk, contains('cxd4 4. Nxd4 Nf6'));
  });

  test('discarding shows the file as it is on disk', () async {
    playTwoNewMoves();
    fixture.session.discardHeld();
    await pumpEventQueue();
    expect(fixture.session.hasHeldEdits, isFalse);
    expect(fixture.session.currentMove?.san, 'cxd4');
    expect(fixture.store.requestedSaves, isEmpty);
  });

  test(
    'undo takes held edits back one at a time, then none are held',
    () async {
      playTwoNewMoves();
      await fixture.session.undo();
      expect(fixture.session.currentMove?.san, 'Nxd4');
      expect(fixture.session.hasHeldEdits, isTrue);
      await fixture.session.undo();
      expect(fixture.session.currentMove?.san, 'cxd4');
      expect(fixture.session.hasHeldEdits, isFalse);
      await pumpEventQueue();
      expect(fixture.store.requestedSaves, isEmpty);
    },
  );

  test('a save after an undo writes only what is left', () async {
    playTwoNewMoves();
    await fixture.session.undo();
    fixture.session.keepHeld();
    await pumpEventQueue();
    expect(fixture.onDisk, contains('cxd4 4. Nxd4'));
    expect(fixture.onDisk, isNot(contains('Nf6')));
  });

  test('held edits stay held when the mode no longer holds them', () async {
    playTwoNewMoves();
    fixture.session.holdsEdits = false;
    fixture.session.setComment(NodePath.of([0]), 'Sharp');
    await pumpEventQueue();
    expect(fixture.store.requestedSaves, isEmpty);
    fixture.session.keepHeld();
    await pumpEventQueue();
    expect(fixture.onDisk, contains('Sharp'));
    expect(fixture.onDisk, contains('Nxd4 Nf6'));
  });

  test('reading the file again throws the held edits away', () async {
    playTwoNewMoves();
    await fixture.session.reloadFromDisk();
    expect(fixture.session.hasHeldEdits, isFalse);
    expect(
      fixture.session.chapter!.tree.nodeAt(NodePath.of([0, 0, 0, 0, 0, 0])),
      isNull,
    );
  });

  test('without holding, a move is saved as before', () async {
    fixture.session.holdsEdits = false;
    fixture.session.goTo(NodePath.of([0, 0, 0, 0, 0]));
    fixture.session.playMove('f3d4');
    await pumpEventQueue();
    expect(fixture.session.hasHeldEdits, isFalse);
    expect(fixture.onDisk, contains('cxd4 4. Nxd4'));
  });

  group('the edit strip', () {
    late ValueNotifier<bool> editing;
    setUp(() => editing = ValueNotifier(false));
    tearDown(() => editing.dispose());

    Future<void> pump(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 600));
      await tester.pumpWidget(
        MaterialApp(
          theme: darkTheme(),
          home: Scaffold(
            body: EditStrip(
              session: fixture.session,
              saver: fixture.saver,
              editing: editing,
            ),
          ),
        ),
      );
    }

    testWidgets('says the moves are unsaved without being asked to edit', (
      tester,
    ) async {
      await pump(tester);
      expect(find.text('Unsaved changes'), findsNothing);
      playTwoNewMoves();
      await tester.pump();
      expect(find.text('Unsaved changes'), findsOneWidget);
      expect(find.byTooltip('Save to the file (Ctrl+S)'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('Save writes them and the strip goes', (tester) async {
      await pump(tester);
      playTwoNewMoves();
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pump();
      expect(find.text('Unsaved changes'), findsNothing);
      await tester.runAsync(pumpEventQueue);
      expect(fixture.onDisk, contains('Nxd4 Nf6'));
    });

    testWidgets('Discard puts the file back', (tester) async {
      await pump(tester);
      playTwoNewMoves();
      await tester.pump();
      await tester.tap(find.text('Discard'));
      await tester.pump();
      expect(find.text('Unsaved changes'), findsNothing);
      expect(fixture.session.currentMove?.san, 'cxd4');
    });
  });
}

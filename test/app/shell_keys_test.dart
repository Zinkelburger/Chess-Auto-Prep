import 'package:chess_auto_prep/app/mode.dart';
import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/features/library/library_panel.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/workspace/comment_field.dart';
import 'package:chess_auto_prep/workspace/game_counter.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_store.dart';
import '../support/viewer_fixture.dart';
import '../support/window_fixture.dart';

/// The keys the window binds: Enter and Esc through
/// the variations, Esc out of whatever the user is in, F11, Ctrl+Shift+V
/// and the viewer's Space.
void main() {
  late WindowFixture w;
  setUp(() => w = WindowFixture());
  tearDown(() => w.dispose());

  Future<void> openKid(WidgetTester tester) async {
    await w.pumpShell(tester);
    await tester.tap(
      find
          .descendant(
            of: find.byType(LibraryPanel),
            matching: find.text('Main'),
          )
          .last,
    );
    await tester.pumpAndSettle();
  }

  Future<void> key(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
  }

  Future<void> ctrl(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool shift = false,
  }) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(key);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  /// What the clipboard answers when the window asks for text.
  void clipboardHolds(WidgetTester tester, String text) {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => switch (call.method) {
        'Clipboard.getData' => {'text': text},
        'Clipboard.hasStrings' => {'value': true},
        _ => null,
      },
    );
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
  }

  testWidgets('Ctrl S saves a comment while typing', (tester) async {
    final ref = collectionRef('review');
    w.store.documents[ref] = Opened(
      threeGameFile,
      scriptedRevision(threeGameFile),
    );
    await w.pumpShell(tester);
    await w.requests.openFile(ref);
    await tester.pumpAndSettle();
    await ctrl(tester, LogicalKeyboardKey.keyE);
    final field = find.descendant(
      of: find.byType(CommentField),
      matching: find.byType(TextField),
    );
    await tester.enterText(field, 'Review note not yet blurred');
    await ctrl(tester, LogicalKeyboardKey.keyS);
    expect(
      (w.store.documents[ref] as Opened).text,
      contains('Review note not yet blurred'),
    );
  });

  testWidgets('Enter steps into the variation at the cursor; Esc goes back '
      'to where it branched', (tester) async {
    await openKid(tester);
    w.session.cursor.goTo(
      NodePath.of([0, 0]),
    ); // 2. Nf3, before 2... d6 (2... Nc6)
    await key(tester, LogicalKeyboardKey.enter);
    expect(w.session.cursor.currentMove?.san, 'Nc6');
    await key(tester, LogicalKeyboardKey.arrowRight);
    expect(w.session.cursor.currentMove?.san, 'd4');
    await key(tester, LogicalKeyboardKey.escape);
    expect(w.session.cursor.value, NodePath.of([0, 0]));
  });

  testWidgets('Enter on a focused button is the button\'s', (tester) async {
    await openKid(tester);
    w.session.cursor.goTo(NodePath.of([0, 0]));
    await tester.pump();
    final forward = find.byTooltip('Forward (→)');
    Focus.of(
      tester.element(find.descendant(of: forward, matching: find.byType(Icon))),
    ).requestFocus();
    await tester.pump();
    await key(tester, LogicalKeyboardKey.enter);
    expect(w.session.cursor.currentMove?.san, 'd6', reason: 'Forward, not Nc6');
  });

  testWidgets('Esc closes the edit strip once out of the variations', (
    tester,
  ) async {
    await openKid(tester);
    await ctrl(tester, LogicalKeyboardKey.keyE);
    expect(find.byType(CommentField), findsOneWidget);
    await key(tester, LogicalKeyboardKey.escape);
    expect(
      find.byType(CommentField),
      findsOneWidget,
      reason: 'Builder notes remain directly editable',
    );
    expect(w.fullScreenAsked, isEmpty, reason: 'one thing at a time');
  });

  testWidgets('F11 fills the screen and Esc leaves it', (tester) async {
    await openKid(tester);
    await key(tester, LogicalKeyboardKey.f11);
    expect(w.fullScreenAsked, [true]);
    await key(tester, LogicalKeyboardKey.escape);
    expect(w.fullScreenAsked, [true, false]);
    await key(tester, LogicalKeyboardKey.escape);
    expect(w.fullScreenAsked, [true, false], reason: 'nothing left to leave');
  });

  testWidgets('Esc in Tactics ends the sitting', (tester) async {
    await w.pumpShell(tester);
    w.requests.switchTo(Mode.tactics);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play (4)'));
    await tester.pumpAndSettle();
    expect(w.trainer.run, isNotNull);
    await key(tester, LogicalKeyboardKey.escape);
    expect(w.trainer.run, isNull);
    expect(w.trainer.recap, isNotNull);
  });

  group('Ctrl+Shift+V', () {
    const fen = '4k3/8/8/8/8/8/4P3/4K3 w - - 0 1';

    testWidgets('puts a FEN on a new analysis board, from a chapter', (
      tester,
    ) async {
      await openKid(tester);
      clipboardHolds(tester, fen);
      await ctrl(tester, LogicalKeyboardKey.keyV, shift: true);
      expect(w.session.isScratch, isTrue);
      expect(w.session.cursor.fen, const Fen(fen));
    });

    testWidgets('leaves the chapter up when the clipboard holds no FEN', (
      tester,
    ) async {
      await openKid(tester);
      clipboardHolds(tester, '1. e4 e5');
      await ctrl(tester, LogicalKeyboardKey.keyV, shift: true);
      expect(w.session.source, kidMain);
      expect(find.text('The clipboard holds no FEN.'), findsOneWidget);
    });
  });

  group('Ctrl+V', () {
    const fen = '4k3/8/8/8/8/8/4P3/4K3 w - - 0 1';

    testWidgets('a FEN in the builder is an analysis board, not a repertoire', (
      tester,
    ) async {
      await openKid(tester);
      clipboardHolds(tester, ' "$fen"\n');
      await ctrl(tester, LogicalKeyboardKey.keyV);
      expect(w.requests.mode, Mode.repertoires);
      expect(w.session.isScratch, isTrue);
      expect(w.session.cursor.fen, const Fen(fen));
      expect(w.store.creates, isEmpty);
    });

    testWidgets('a PGN in the PGN Viewer is an analysis board', (tester) async {
      final games = collectionRef('games');
      w.store.documents[games] = Opened(
        threeGameFile,
        scriptedRevision(threeGameFile),
      );
      await w.pumpShell(tester);
      await w.requests.openFile(games);
      await tester.pumpAndSettle();
      clipboardHolds(tester, '1. e4 c5 2. Nf3');
      await ctrl(tester, LogicalKeyboardKey.keyV);
      expect(w.requests.mode, Mode.pgnViewer);
      expect(w.session.isScratch, isTrue);
      expect(w.session.cursor.currentMove?.san, 'Nf3');
    });

    testWidgets('a FEN cut short is read, facing the side to move', (
      tester,
    ) async {
      await openKid(tester);
      clipboardHolds(tester, '4k3/8/8/8/8/8/4P3/4K3 b');
      await ctrl(tester, LogicalKeyboardKey.keyV);
      expect(w.session.isScratch, isTrue);
      expect(
        w.session.cursor.fen,
        const Fen('4k3/8/8/8/8/8/4P3/4K3 b - - 0 1'),
      );
      expect(w.session.orientation, Side.black);
    });

    testWidgets('from a mode with no board, the board comes up in the '
        'builder', (tester) async {
      await w.pumpShell(tester);
      w.requests.switchTo(Mode.databases);
      await tester.pumpAndSettle();
      clipboardHolds(tester, fen);
      await ctrl(tester, LogicalKeyboardKey.keyV);
      expect(w.requests.mode, Mode.repertoires);
      expect(w.session.cursor.fen, const Fen(fen));
    });
  });

  group('Set up position', () {
    const fen = '4k3/8/8/8/8/8/4P3/4K3 w - - 0 1';

    testWidgets('edits the position on the board into a new analysis board, '
        'the same way up', (tester) async {
      await openKid(tester);
      w.session.cursor.forward();
      await tester.pumpAndSettle();
      final here = w.session.cursor.fen;
      await ctrl(tester, LogicalKeyboardKey.keyE, shift: true);
      expect(find.text('Set up a position'), findsOneWidget);
      final field = find.widgetWithText(TextField, 'FEN');
      expect(tester.widget<TextField>(field).controller!.text, here.value);
      await tester.enterText(field, fen);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use this position'));
      await tester.pumpAndSettle();
      expect(w.session.isScratch, isTrue);
      expect(w.session.cursor.fen, const Fen(fen));
      expect(w.session.orientation, Side.black, reason: 'KID is for Black');
      expect(w.store.creates, isEmpty);
    });

    testWidgets('Cancel leaves the board as it was', (tester) async {
      await openKid(tester);
      await ctrl(tester, LogicalKeyboardKey.keyE, shift: true);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(w.session.source, kidMain);
    });
  });

  testWidgets('Space in the PGN Viewer plays the game through until the '
      'user takes the board back', (tester) async {
    final games = collectionRef('games');
    w.store.documents[games] = Opened(
      threeGameFile,
      scriptedRevision(threeGameFile),
    );
    await w.pumpShell(tester);
    await w.requests.openFile(games);
    await tester.pumpAndSettle();
    expect(w.requests.mode, Mode.pgnViewer);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump(const Duration(milliseconds: 300));
    expect(w.session.cursor.currentMove?.san, 'e4');
    await tester.pump(const Duration(seconds: 1));
    expect(w.session.cursor.currentMove?.san, 'e5');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump(const Duration(seconds: 3));
    expect(
      w.session.cursor.currentMove?.san,
      'e4',
      reason: 'the arrow stopped it',
    );
  });

  testWidgets('once the game box lets go of the focus, the keys are the '
      'workspace\'s again', (tester) async {
    final games = collectionRef('games');
    w.store.documents[games] = Opened(
      threeGameFile,
      scriptedRevision(threeGameFile),
    );
    await w.pumpShell(tester);
    await w.requests.openFile(games);
    await tester.pumpAndSettle();
    final box = find.descendant(
      of: find.byType(GameCounter),
      matching: find.byType(TextField),
    );
    await tester.tap(box);
    await tester.enterText(box, '2');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(w.session.game, 1);
    await key(tester, LogicalKeyboardKey.arrowRight);
    expect(w.session.cursor.currentMove?.san, 'd4');
    final side = w.session.orientation;
    await key(tester, LogicalKeyboardKey.keyF);
    expect(w.session.orientation, isNot(side));
  });

  testWidgets('autoplay stops when the viewer is left', (tester) async {
    final games = collectionRef('games');
    w.store.documents[games] = Opened(
      threeGameFile,
      scriptedRevision(threeGameFile),
    );
    await w.pumpShell(tester);
    await w.requests.openFile(games);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump(const Duration(milliseconds: 300));
    expect(w.parts.documents.autoplay.playing, isTrue);
    w.requests.switchTo(Mode.study);
    await tester.pump(const Duration(seconds: 3));
    expect(w.parts.documents.autoplay.playing, isFalse);
    // Study has a board of its own; the game waits in the viewer where
    // autoplay left it.
    expect(w.session.source, isNot(games));
    w.requests.switchTo(Mode.pgnViewer);
    await tester.pumpAndSettle();
    expect(w.session.source, games);
    expect(w.session.cursor.currentMove?.san, 'e4');
  });
}

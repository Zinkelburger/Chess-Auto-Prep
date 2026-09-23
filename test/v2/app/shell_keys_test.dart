import 'package:chess_auto_prep/v2/app/mode.dart';
import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/features/library/library_panel.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/workspace/comment_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_store.dart';
import '../support/viewer_fixture.dart';
import '../support/window_fixture.dart';

/// The keys the old app had that the window binds: Enter and Esc through
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

  testWidgets('Enter steps into the variation at the cursor; Esc goes back '
      'to where it branched', (tester) async {
    await openKid(tester);
    w.session.goTo(NodePath.of([0, 0])); // 2. Nf3, before 2... d6 (2... Nc6)
    await key(tester, LogicalKeyboardKey.enter);
    expect(w.session.currentMove?.san, 'Nc6');
    await key(tester, LogicalKeyboardKey.arrowRight);
    expect(w.session.currentMove?.san, 'd4');
    await key(tester, LogicalKeyboardKey.escape);
    expect(w.session.cursor, NodePath.of([0, 0]));
  });

  testWidgets('Enter on a focused button is the button\'s', (tester) async {
    await openKid(tester);
    w.session.goTo(NodePath.of([0, 0]));
    await tester.pump();
    final forward = find.byTooltip('Forward (→)');
    Focus.of(
      tester.element(find.descendant(of: forward, matching: find.byType(Icon))),
    ).requestFocus();
    await tester.pump();
    await key(tester, LogicalKeyboardKey.enter);
    expect(w.session.currentMove?.san, 'd6', reason: 'Forward, not Nc6');
  });

  testWidgets('Esc closes the edit strip once out of the variations', (
    tester,
  ) async {
    await openKid(tester);
    await ctrl(tester, LogicalKeyboardKey.keyE);
    expect(find.byType(CommentField), findsOneWidget);
    await key(tester, LogicalKeyboardKey.escape);
    expect(find.byType(CommentField), findsNothing);
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
      expect(w.session.fen, const Fen(fen));
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
    expect(w.session.currentMove?.san, 'e4');
    await tester.pump(const Duration(seconds: 1));
    expect(w.session.currentMove?.san, 'e5');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump(const Duration(seconds: 3));
    expect(w.session.currentMove?.san, 'e4', reason: 'the arrow stopped it');
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
    expect(w.session.currentMove?.san, 'e4');
  });
}

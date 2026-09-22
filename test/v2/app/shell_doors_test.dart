import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/features/library/library_panel.dart';
import 'package:chess_auto_prep/v2/features/pgn_viewer/pgn_viewer_panel.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_explorer.dart';
import '../support/scripted_store.dart';
import '../support/window_fixture.dart';

/// The window's doors to a document from outside the lists: a file from the
/// desktop, the clipboard, a game the explorer lists.
void main() {
  final kid = kidMain;

  Finder inLibrary(Finder row) =>
      find.descendant(of: find.byType(LibraryPanel), matching: row);
  late WindowFixture w;
  setUp(() => w = WindowFixture());
  tearDown(() => w.dispose());
  Future<void> pump(WidgetTester tester) => w.pumpShell(tester);

  const pasted = '[Event "x"]\n[Result "*"]\n\n1. e4 e5 (1... c5) *\n';

  /// What the clipboard answers when the shell asks for text.
  void clipboardHolds(WidgetTester tester, String? text) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => switch (call.method) {
        'Clipboard.getData' => text == null ? null : {'text': text},
        'Clipboard.hasStrings' => {'value': text != null},
        _ => null,
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
  }

  Future<void> pressCtrl(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  testWidgets('the builder offers Open PGN file and Paste PGN, the viewer '
      'Open and Close file', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Actions'));
    await tester.pumpAndSettle();
    expect(find.text('Open PGN file…'), findsOneWidget);
    expect(find.text('Paste PGN'), findsOneWidget);
    expect(find.text('Ctrl+V'), findsOneWidget);
    expect(find.text('Close file'), findsNothing);
    await tester.tap(find.text('Actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Repertoire builder'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('PGN Viewer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Actions'));
    await tester.pumpAndSettle();
    // The viewer's own empty list offers the file dialog too.
    expect(find.text('Open PGN file…'), findsAtLeastNWidgets(1));
    expect(find.text('Paste PGN'), findsNothing);
    expect(find.text('Close file'), findsOneWidget);
  });

  testWidgets('Ctrl+V in the builder makes a repertoire of the clipboard and '
      'opens it, asking which side it is for', (tester) async {
    await pump(tester);
    clipboardHolds(tester, pasted);
    await pressCtrl(tester, LogicalKeyboardKey.keyV);
    expect(w.session.source?.path, '/repertoires/Pasted repertoire/Main.pgn');
    expect(w.session.chapter?.gameCount, 2, reason: 'the variation is a line');
    expect(
      w.store.documents.keys.map((ref) => ref.path),
      contains('/repertoires/Pasted repertoire/Main.pgn'),
    );
    expect(find.text('Which side is Main for?'), findsOneWidget);
  });

  testWidgets('Paste PGN in the Actions menu does the same', (tester) async {
    await pump(tester);
    clipboardHolds(tester, pasted);
    await tester.tap(find.text('Actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paste PGN'));
    await tester.pumpAndSettle();
    expect(w.session.source?.path, '/repertoires/Pasted repertoire/Main.pgn');
  });

  testWidgets('an empty clipboard says so and writes nothing', (tester) async {
    await pump(tester);
    clipboardHolds(tester, null);
    await pressCtrl(tester, LogicalKeyboardKey.keyV);
    expect(find.text('Nothing to paste: copy a PGN first.'), findsOneWidget);
    expect(w.session.source, isNull);
  });

  testWidgets('a clipboard with no moves is refused in plain English', (
    tester,
  ) async {
    await pump(tester);
    clipboardHolds(tester, 'just words');
    await pressCtrl(tester, LogicalKeyboardKey.keyV);
    expect(find.text('That PGN has no moves to train.'), findsOneWidget);
    expect(
      w.store.documents.keys.map((ref) => ref.path),
      isNot(contains(contains('Pasted'))),
    );
  });

  testWidgets('Ctrl+O in the builder imports the chosen file as a repertoire', (
    tester,
  ) async {
    await pump(tester);
    w.libraryPicker.answer = '/downloads/Italian.pgn';
    w.store.documents[const DocumentRef('/downloads/Italian.pgn')] = Opened(
      pasted,
      scriptedRevision(pasted),
      readOnly: 'outside Documents',
    );
    await pressCtrl(tester, LogicalKeyboardKey.keyO);
    expect(w.session.source?.path, '/repertoires/Italian/Main.pgn');
  });

  testWidgets('a file that cannot be read is said in a sentence', (
    tester,
  ) async {
    await pump(tester);
    w.libraryPicker.answer = '/downloads/gone.pgn';
    await pressCtrl(tester, LogicalKeyboardKey.keyO);
    expect(find.text('Could not read that file.'), findsOneWidget);
  });

  testWidgets('a game the explorer lists opens in the PGN Viewer at the '
      'ply the explorer was showing', (tester) async {
    await pump(tester);
    await tester.tap(inLibrary(find.text('Main')).last); // KID
    await tester.pumpAndSettle();
    w.session.forward();
    final ply = w.explorer.ply;
    expect(ply, greaterThan(0));
    await tester.tap(find.text('Explorer'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Carlsen, M'));
    await tester.pumpAndSettle();

    final opened = w.session.source!;
    expect(opened.path, startsWith('$explorerCollections/explorer games/'));
    expect(opened.path, contains('abcd1234'));
    expect(w.session.game, 0);
    expect(
      w.session.cursor,
      NodePath.of(List.filled(ply, 0)),
      reason: 'at the ply the explorer was showing',
    );
    expect(find.byType(PgnViewerPanel), findsOneWidget);
    expect(find.byType(LibraryPanel), findsNothing);
    expect(w.recent.saved.last.first, opened.path, reason: 'remembered');
  });

  testWidgets('an explorer game that cannot be fetched is said in the bar '
      'and nothing moves', (tester) async {
    await pump(tester);
    await tester.tap(inLibrary(find.text('Main')).last); // KID
    await tester.pumpAndSettle();
    w.lichess.pgn = null;
    await tester.tap(find.text('Explorer'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Carlsen, M'));
    await tester.pumpAndSettle();
    expect(find.text('Could not fetch that game.'), findsOneWidget);
    expect(w.session.source, kid);
    expect(find.byType(LibraryPanel), findsOneWidget);
  });
}

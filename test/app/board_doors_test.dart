// The ways a position comes onto a board from outside a file, on their
// own: a find from the Positions, Ctrl+V on a mode's own screen, and the
// board's entries in the Actions menu.
import 'package:chess_auto_prep/app/board_doors.dart';
import 'package:chess_auto_prep/app/mode.dart';
import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/generation/finds.dart';
import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/pgn/game_text.dart';
import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/storage/finds_store.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/ui/app_action.dart';
import 'package:chess_auto_prep/ui/app_keys.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/study_fixture.dart';
import '../support/window_fixture.dart';

void main() {
  late WindowFixture w;
  late bool inspecting;
  late BoardDoors doors;
  setUp(() {
    w = WindowFixture();
    inspecting = false;
    doors = BoardDoors(
      requests: w.requests,
      workspace: w.parts.workspace,
      inspecting: () => inspecting,
    );
  });
  tearDown(() => w.dispose());

  KeptFind kept(Fen root, List<String> sans) => KeptFind(
    id: 1,
    find: Find(
      kind: FindKind.trap,
      sans: sans,
      ply: sans.length,
      keyPly: 0,
      fen: root,
      evalCp: 0,
      lossCp: 0,
      share: 0,
      reach: 1,
      worth: 1,
    ),
    side: Side.black,
    rootFen: root,
    elo: 1500,
    foundAt: DateTime(2026),
  );

  group('a find', () {
    late List<String> line;
    late Fen root;
    setUp(() async {
      await w.requests.open(kidMain);
      root = w.session.tree!.rootFen;
      line = [for (final node in w.session.tree!.mainLine.take(2)) node.san];
    });

    test('the open chapter plays is shown in it', () async {
      doors.openFind(kept(root, line));
      await pumpEventQueue();
      expect(w.session.source, kidMain);
      expect(w.session.cursor.value, NodePath.of(const [0, 0]));
    });

    test('goes to an analysis board while the Analysis tab is up', () async {
      inspecting = true;
      doors.openFind(kept(root, line));
      await pumpEventQueue();
      expect(w.session.isScratch, isTrue);
    });

    test('from another position goes to an analysis board', () async {
      const elsewhere = Fen(
        'rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq - 0 1',
      );
      doors.openFind(kept(elsewhere, const ['d5']));
      await pumpEventQueue();
      expect(w.session.isScratch, isTrue);
    });
  });

  test('on an analysis board, a find goes to another', () async {
    w.session.playMove('d2d4');
    doors.openFind(kept(Fen.initial, const ['d4']));
    await pumpEventQueue();
    expect(w.session.isScratch, isTrue);
    expect(w.requests.documents.tabs.open, hasLength(2));
  });

  group('Ctrl+V on a mode\'s own screen', () {
    Future<void> screen(WidgetTester tester, {bool field = false}) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async => null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: doors.onScreen(
              Focus(
                autofocus: !field,
                child: field
                    ? const TextField(autofocus: true)
                    : const SizedBox(),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    Future<void> ctrl(WidgetTester tester, LogicalKeyboardKey key) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(key);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.runAsync(() => pumpEventQueue());
    }

    testWidgets('pastes, and says what the clipboard held', (tester) async {
      await screen(tester);
      await ctrl(tester, LogicalKeyboardKey.keyC);
      expect(w.requests.status, isNull);
      await ctrl(tester, LogicalKeyboardKey.keyV);
      expect(w.requests.status, 'Nothing to paste: copy a PGN or FEN first.');
    });

    testWidgets('is the field\'s while a field has the caret', (tester) async {
      await screen(tester, field: true);
      await ctrl(tester, LogicalKeyboardKey.keyV);
      expect(w.requests.status, isNull);
    });

    test('a mode without a screen of its own gets none', () {
      expect(doors.onScreen(null), isNull);
    });
  });

  group('the board\'s entries in the Actions menu', () {
    Future<BuildContext> context(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(navigatorKey: w.navigator, home: const SizedBox()),
      );
      return tester.element(find.byType(SizedBox));
    }

    List<String> labels(List<AppAction> actions) => [
      for (final action in actions) action.label,
    ];

    testWidgets('paste the clipboard unless told to take a FEN only', (
      tester,
    ) async {
      final at = await context(tester);
      expect(labels(doors.entries(at)), [
        AppKey.paste.action,
        'Edit position…',
      ]);
      expect(labels(doors.entries(at, paste: false)).first, 'Paste FEN');
    });

    testWidgets(
      'adding a pasted game to a study keeps its players and result',
      (tester) async {
        const pgn =
            '[Event "Club championship"]\n'
            '[White "Rivera"]\n[Black "Chen"]\n[Result "1-0"]\n\n'
            '1. e4 e5 2. Bc4 Nc6 3. Qh5 Nf6 4. Qxf7# 1-0';
        final messenger = tester.binding.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async =>
              call.method == 'Clipboard.getData' ? {'text': pgn} : null,
        );
        addTearDown(
          () =>
              messenger.setMockMethodCallHandler(SystemChannels.platform, null),
        );
        w.requests.switchTo(Mode.study);
        await doors.paste();

        final at = await context(tester);
        final actions = boardActions(
          at,
          doors: doors,
          library: w.library,
          onAnalyze: null,
        );
        actions
            .singleWhere((action) => action.label == 'Add game to study…')
            .run!();
        await tester.pumpAndSettle();
        await tester.tap(find.text('New study…'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextField, 'Study name'),
          'Club',
        );
        await tester.tap(find.text('Create'));
        await tester.pumpAndSettle();

        final saved = w.store.documents[studyRef('Club')]! as Opened;
        final game = parseChapter(name: 'Club', text: saved.text).lines.single;
        expect(game.tree!.mainLine.last.san, 'Qxf7#');
        expect(tagValue(game.tags, 'White'), 'Rivera');
        expect(tagValue(game.tags, 'Black'), 'Chen');
        expect(tagValue(game.tags, 'Result'), '1-0');
        expect(game.terminator, '1-0');
      },
    );

    testWidgets('take a FEN only over a repertoire file, where Ctrl+V makes '
        'a repertoire', (tester) async {
      final at = await context(tester);
      final library = w.parts.documents.library;
      List<String> board({VoidCallback? onAnalyze}) => labels(
        boardActions(at, doors: doors, library: library, onAnalyze: onAnalyze),
      );
      w.requests.switchTo(Mode.repertoires);
      expect(board(), contains('Save to repertoire…'));
      expect(board(), contains(AppKey.paste.action));
      expect(board(), isNot(contains(AppKey.analysisBoard.action)));
      expect(board(onAnalyze: () {}).first, AppKey.analysisBoard.action);
      await tester.runAsync(() => w.requests.open(kidMain));
      expect(board(), contains('Paste FEN'));
      expect(board(), isNot(contains('Save to repertoire…')));
      w.requests.switchTo(Mode.trainer);
      expect(board(), contains('Paste FEN'));
      w.requests.switchTo(Mode.pgnViewer);
      expect(board(), contains(AppKey.paste.action));
    });
  });
}

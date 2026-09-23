import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/pgn/analysis_board.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/workspace/document_saver.dart';
import 'package:chess_auto_prep/v2/workspace/document_session.dart';
import 'package:chess_auto_prep/v2/workspace/save_state.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';
import '../support/scripted_store.dart';
import '../support/session_fixture.dart';

const _afterE4 = Fen(
  'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
);

const _sicilian =
    'rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2';

void main() {
  late ScriptedDocumentStore store;
  late DocumentSaver saver;
  late DocumentSession session;

  setUp(() {
    store = ScriptedDocumentStore();
    saver = DocumentSaver(store, delay: Duration.zero);
    session = DocumentSession(store, saver);
  });

  tearDown(() {
    session.dispose();
    saver.dispose();
  });

  /// [text] onto the board as Ctrl+V puts it there: the reason it was
  /// refused, or null.
  Future<String?> paste(String text) async {
    switch (pastedBoard(text, side: session.orientation)) {
      case PasteRefused(:final reason):
        return reason;
      case PastedBoard(:final chapter):
        await session.showAnalysisBoard(chapter);
        return null;
    }
  }

  List<String> line() => [
    for (final node in session.tree!.lineTo(session.cursor)) node.san,
  ];

  test('the window starts on an empty analysis board facing White', () {
    expect(session.isScratch, isTrue);
    expect(session.chapter?.name, analysisBoardName);
    expect(session.fen, Fen.initial);
    expect(session.orientation, Side.white);
    expect(session.canUndo, isFalse);
  });

  test('moves, variations and notes stay in memory', () async {
    session
      ..playMove('e2e4')
      ..playMove('c7c5')
      ..back()
      ..playMove('e7e5');
    session.setComment(session.cursor, 'Open game');
    await pumpEventQueue();
    expect(line(), ['e4', 'e5']);
    expect(session.tree!.children.single.children.map((n) => n.san), [
      'c5',
      'e5',
    ]);
    expect(session.commentAt(session.cursor), 'Open game');
    expect(store.requestedSaves, isEmpty);
    expect(store.creates, isEmpty);
    expect(saver.state, isA<Saved>());
  });

  test('undo steps back through the board edits, then refuses', () async {
    session
      ..playMove('e2e4')
      ..playMove('e7e5');
    expect(session.canUndo, isTrue);
    expect(await session.undo(), isA<Restored>());
    expect(line(), ['e4']);
    expect(await session.undo(), isA<Restored>());
    expect(session.tree!.children, isEmpty);
    expect(session.cursor.isRoot, isTrue);
    expect(await session.undo(), isA<UndoRefused>());
  });

  test('flipping the board changes the side it is played for', () {
    session.flip();
    expect(session.orientation, Side.black);
    expect(session.chapter!.side, Side.black);
    expect(session.flipped, isFalse);
  });

  group('paste', () {
    test('a PGN keeps its variations and comments', () async {
      final refusal = await paste(
        '[Event "x"]\n\n1. e4 {King pawn} c5 (1... e5 2. Nf3) 2. Nf3 *',
      );
      expect(refusal, isNull);
      expect(line(), ['e4', 'c5', 'Nf3'], reason: 'the cursor is at the end');
      expect(session.tree!.children.single.comment, 'King pawn');
      expect(session.tree!.children.single.children.length, 2);
    });

    test('bare moves are a game', () async {
      expect(await paste('1.e4 c5 2.Nf3'), isNull);
      expect(line(), ['e4', 'c5', 'Nf3']);
    });

    test('a FEN is where the board starts, counters or not', () async {
      final fields = _sicilian.split(' ').take(4).join(' ');
      expect(await paste(fields), isNull);
      expect(session.tree!.rootFen, Fen('$fields 0 1'));
      session.playMove('g1f3');
      expect(line(), ['Nf3']);
    });

    test('text with no game is refused and the board kept', () async {
      session.playMove('d2d4');
      expect(
        await paste('hello there'),
        startsWith('The clipboard holds no game'),
      );
      expect(await paste('  '), contains('Nothing to paste'));
      expect(line(), ['d4']);
    });

    test('the pasted board keeps the side the board faces', () async {
      session.flip();
      await paste('1.e4 c5');
      expect(session.orientation, Side.black);
    });
  });

  group('beside a file', () {
    late SessionFixture file;

    setUp(() async {
      file = await openSession(blackChapter);
    });

    tearDown(() => file.dispose());

    test('opening a file puts the board aside, as it was left', () async {
      final session = file.session;
      await session.showAnalysisBoard();
      session
        ..playMove('d2d4')
        ..playMove('d7d5')
        ..back();
      await session.open(file.ref);
      expect(session.isScratch, isFalse);
      expect(session.source, file.ref);
      await session.showAnalysisBoard();
      expect(session.isScratch, isTrue);
      expect(session.currentMove?.san, 'd4', reason: 'where the user was');
      expect(session.canUndo, isTrue, reason: 'its history went with it');
    });

    test('a new board from here keeps the root and the side', () async {
      final session = file.session;
      session
        ..forward()
        ..forward();
      final sans = [
        for (final node in session.tree!.lineTo(session.cursor)) node.san,
      ];
      await session.showAnalysisBoard(
        analysisBoard(
          side: session.orientation,
          root: session.tree!.rootFen,
          sans: sans,
        ),
      );
      expect(session.isScratch, isTrue);
      expect(session.source, isNull);
      expect(session.orientation, Side.black);
      expect(session.tree!.rootFen, _afterE4);
      expect(session.currentMove?.san, 'Nf3');
      expect(session.canUndo, isFalse, reason: 'a new board has no history');
    });
  });

  group('leaving a file', () {
    late SessionFixture file;

    setUp(() async {
      file = await openSession(blackChapter);
    });

    tearDown(() => file.dispose());

    test('closing the file shows the board', () {
      file.session.closed();
      expect(file.session.isScratch, isTrue);
    });

    test('the board never writes the file it was made from', () async {
      final before = file.onDisk;
      await file.session.showAnalysisBoard(analysisBoard(side: Side.black));
      file.session.playMove('e2e4');
      await pumpEventQueue();
      expect(file.onDisk, before);
    });
  });

  test('a board from a position with no moves takes its first move', () {
    final board = analysisBoard(side: Side.white, root: Fen(_sicilian));
    expect(board.tree.rootFen, Fen(_sicilian));
    expect(board.tree.children, isEmpty);
    expect(board.tree.nodeAt(const NodePath.root()), isNull);
  });
}

import 'package:chess_auto_prep/chess/pgn/board_shapes.dart';
import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/chess/pv_text.dart';
import 'package:chess_auto_prep/workspace/move_shapes.dart';
import 'package:dartchess/dartchess.dart' show Square;
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';
import '../support/session_fixture.dart';

const _arrow = BoardShape(Square.g1, Square.f3, ShapeColour.green);

void main() {
  late SessionFixture fixture;

  setUp(() async => fixture = await openSession(blackChapter));
  tearDown(() => fixture.dispose());

  test('a shape drawn on a move is written into its comment beside the '
      'words and the evaluation, and saved', () async {
    final session = fixture.session;
    // 1... c5 {The Sicilian [%eval 0.30]}
    session.goTo(NodePath.of(const [0]));
    expect(drawsIntoComment(session, editing: false), isTrue);
    drawIntoComment(session, _arrow);
    expect(
      session.commentAt(session.cursor),
      'The Sicilian [%eval 0.30] [%cal Gg1f3]',
    );
    expect(shapesOnBoard(session, null), [_arrow]);
    await pumpEventQueue();
    expect(
      fixture.onDisk,
      contains('{The Sicilian [%eval 0.30] [%cal Gg1f3]}'),
    );

    drawIntoComment(session, _arrow);
    expect(session.commentAt(session.cursor), 'The Sicilian [%eval 0.30]');
    expect(shapesOnBoard(session, null), isEmpty);
  });

  test('the threat is drawn in red only on the position it is for', () {
    final session = fixture.session;
    final threat = (fen: session.boardFen, uci: 'g1f3');
    expect(shapesOnBoard(session, threat), [
      const BoardShape(Square.g1, Square.f3, ShapeColour.red),
    ]);
    session.forward();
    expect(shapesOnBoard(session, threat), isEmpty);
  });

  test('the threat is not drawn while the rest of the game is hidden', () {
    final session = fixture.session;
    final threat = (fen: session.boardFen, uci: 'g1f3');
    // A solitaire game or a puzzle shows the game only as far as the move
    // under the cursor: the threat would point at the answer.
    session.showOnlyTo(session.cursor);
    expect(shapesOnBoard(session, threat), isEmpty);
    session.showOnlyTo(null);
    expect(shapesOnBoard(session, threat), hasLength(1));
  });

  test(
    'shapes stay on the board where the document does not take them',
    () async {
      final session = fixture.session;
      session.goTo(NodePath.of(const [0]));
      // The viewer holds its edits: only while its editing is open.
      session.holdsEdits = true;
      expect(drawsIntoComment(session, editing: false), isFalse);
      expect(drawsIntoComment(session, editing: true), isTrue);
      session.holdsEdits = false;
      // A line read out of a comment is not the move's position.
      session.showCommentLine(
        session.cursor,
        pvMoves(session.fen, const ['f2f4']),
        0,
      );
      expect(drawsIntoComment(session, editing: false), isFalse);
      expect(shapesOnBoard(session, null), isEmpty);

      final readOnly = await openSession(blackChapter, readOnly: 'outside');
      addTearDown(readOnly.dispose);
      expect(drawsIntoComment(readOnly.session, editing: true), isFalse);
    },
  );
}

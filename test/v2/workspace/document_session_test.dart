import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/workspace/document_session.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';

void main() {
  late DocumentSession session;
  var notifications = 0;

  setUp(() {
    session = DocumentSession()..addListener(() => notifications++);
    notifications = 0;
    session.open(parseChapter(name: 'Main', text: blackChapter));
  });

  test('opening a chapter shows its root from its side', () {
    expect(session.cursor.isRoot, isTrue);
    expect(session.fen.whiteToMove, isFalse);
    expect(session.orientation, Side.black);
    expect(session.currentMove, isNull);
    expect(notifications, 1);
  });

  test('forward and back walk the main line', () {
    session.forward();
    expect(session.currentMove?.san, 'c5');
    session.forward();
    expect(session.currentMove?.san, 'Nf3');
    session.back();
    expect(session.currentMove?.san, 'c5');
    session.back();
    expect(session.cursor.isRoot, isTrue);
    session.back();
    expect(notifications, 5, reason: 'backing off the root does nothing');
  });

  test('goTo ignores paths outside the tree', () {
    session.goTo(NodePath.of([0, 1]));
    expect(session.currentMove?.san, 'Nc3');
    session.goTo(NodePath.of([9]));
    expect(session.currentMove?.san, 'Nc3');
  });

  test('toEnd follows the main line from the cursor; toStart returns', () {
    session.goTo(NodePath.of([0, 0, 1]));
    session.toEnd();
    expect(session.currentMove?.san, 'd4');
    expect(session.cursor, NodePath.of([0, 0, 1, 0]));
    session.toStart();
    expect(session.cursor.isRoot, isTrue);
  });
}

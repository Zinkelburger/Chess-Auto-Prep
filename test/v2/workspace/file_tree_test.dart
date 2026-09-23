import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/pgn/analysis_board.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/workspace/file_filter.dart';
import 'package:chess_auto_prep/v2/workspace/local_games.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

import '../support/big_chapter.dart';
import '../support/scripted_explorer.dart';
import '../support/scripted_store.dart';
import '../support/viewer_fixture.dart';

/// The position after 1. d4 d5, where every line of [bigChapter] passes.
const afterD4D5 = Fen(
  'rnbqkbnr/ppp1pppp/8/3p4/3P4/8/PPP1PPPP/RNBQKBNR w KQkq - 0 2',
);

void main() {
  late ViewerFixture fixture;
  late FileTree tree;
  late List<TreeState> states;

  Future<void> over(String text) async {
    fixture = await viewerOver(text);
    await fixture.open();
    tree = FileTree(session: fixture.session, filter: fixture.filter);
    states = [];
    tree.addListener(() => states.add(tree.state));
  }

  tearDown(() {
    tree.dispose();
    fixture.dispose();
  });

  /// Another file in the collections folder, holding [text].
  Future<void> openOther(String text) async {
    final other = collectionRef('other');
    fixture.store.documents[other] = Opened(text, scriptedRevision(text));
    await fixture.session.open(other, game: 0);
  }

  test('nothing is built until the explorer looks', () async {
    await over(threeGameFile);
    expect(tree.state, isA<TreeUnbuilt>());
    expect(tree.answerAt(Fen.initial), isNull);
    expect(tree.summary, isNull);
  });

  test('a small file is built at once: its games merged by position, with '
      'how they ended', () async {
    await over(threeGameFile);
    tree.want();
    await settled(tree);
    final start = tree.answerAt(Fen.initial)!;
    expect(movesOf(start), ['e2e4', 'd2d4', 'c2c4']);
    expect(start.moves.first.white, 1);
    expect(start.moves[1].draws, 1);
    expect(start.moves.last.undecided, 1);
    expect(tree.summary, '3 games');
    expect(tree.gamePgn('1'), contains('Ding, Liren'));
    expect(tree.gamePgn('9'), isNull);
  });

  test(
    'the viewer\'s filter narrows the answers without building again',
    () async {
      await over(threeGameFile);
      tree.want();
      await settled(tree);
      final built = states.length;
      fixture.filter.apply(
        const GameFilter(
          rules: [HeaderRule(field: 'Event', value: 'Tata')],
        ),
      );
      expect(movesOf(tree.answerAt(Fen.initial)), ['e2e4', 'd2d4']);
      expect(tree.summary, '2 of 3 games');
      expect(states.skip(built), everyElement(isA<TreeBuilt>()));
    },
  );

  test('switching games reads nothing again', () async {
    await over(threeGameFile);
    tree.want();
    await settled(tree);
    fixture.session.showGame(2);
    expect(tree.state, isA<TreeBuilt>());
    expect(movesOf(tree.answerAt(Fen.initial)), hasLength(3));
  });

  test('a large file is built on another isolate, saying how far it has '
      'got', () async {
    await over(bigChapter(games: 1500));
    tree.want();
    expect(tree.state, isA<TreeReading>());
    await settled(tree);
    expect(tree.state, isA<TreeBuilt>());
    expect(
      states.whereType<TreeReading>().map((s) => s.done),
      contains(greaterThan(0)),
    );
    expect(tree.answerAt(afterD4D5)!.total, 1500);
  });

  group('the file leaving stops its build and drops its tree:', () {
    Future<void> leaving(Future<void> Function() leave) async {
      await over(bigChapter(games: 1500));
      tree.want();
      expect(tree.state, isA<TreeReading>());
      await leave();
      expect(tree.state, isA<TreeUnbuilt>());
      expect(tree.answerAt(afterD4D5), isNull);
      // Long enough for the old build to have finished had it gone on.
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(tree.answerAt(afterD4D5), isNull);
      expect(states.whereType<TreeBuilt>(), isEmpty);
      tree.want();
      await settled(tree);
      expect(tree.answerAt(afterD4D5)?.isEmpty ?? true, isTrue);
    }

    test('another file opened', () => leaving(() => openOther(threeGameFile)));

    test('a game pasted onto the board', () async {
      await leaving(
        () =>
            fixture.session.showAnalysisBoard(analysisBoard(side: Side.white)),
      );
    });

    test('the file closed', () async {
      await leaving(() async => fixture.session.closed());
    });
  });

  test('the same file read again after a conflict keeps answering until '
      'the new tree is built', () async {
    await over(threeGameFile);
    tree.want();
    await settled(tree);
    fixture.store.documents[fixture.ref] = Opened(
      '$threeGameFile\n[Event "Late"]\n[Result "0-1"]\n\n1. g3 0-1\n',
      scriptedRevision('late'),
    );
    await fixture.session.reloadFromDisk();
    expect(tree.state, isA<TreeUnbuilt>());
    expect(movesOf(tree.answerAt(Fen.initial)), hasLength(3));
    tree.want();
    await settled(tree);
    expect(movesOf(tree.answerAt(Fen.initial)), contains('g2g3'));
  });

  test('an edit that lands mid-build starts again and never shows the '
      'overtaken tree', () async {
    await over(bigChapter(games: 1500));
    tree.want();
    fixture.session.setComment(NodePath.of([0]), 'A note');
    expect(tree.state, isA<TreeUnbuilt>());
    tree.want();
    await settled(tree);
    expect(states.whereType<TreeBuilt>(), hasLength(1));
    expect(tree.answerAt(afterD4D5)!.total, 1500);
  });

  test('a file of games with no moves says so', () async {
    await over('[Event "Empty"]\n\n*\n');
    tree.want();
    await settled(tree);
    expect(tree.state, isA<TreeEmpty>());
  });
}

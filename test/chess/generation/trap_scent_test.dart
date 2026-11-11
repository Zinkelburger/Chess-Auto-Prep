import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/generation/eval.dart';
import 'package:chess_auto_prep/chess/generation/search_node.dart';
import 'package:chess_auto_prep/chess/generation/trap_scent.dart';
import 'package:flutter_test/flutter_test.dart';

/// A made-up position called [name]: the rule never looks at the chess.
Fen board(String name) => Fen('$name w - - 0 1');

SearchNode leaf(String name, int cp) =>
    HorizonNode(fen: board(name), evalForUs: Eval(cp));

SearchNode ours(String name, List<(String, SearchNode)> moves) => OurNode.over(
  fen: board(name),
  evalForUs: const Eval(0),
  candidates: [
    for (final (uci, child) in moves)
      CandidateMove(
        move: MoveRef(uci: uci, san: uci),
        child: child,
      ),
  ],
);

SearchNode theirs(
  String name,
  List<(String, double, SearchNode)> replies, {
  int cp = 0,
}) => OpponentNode.over(
  fen: board(name),
  evalForUs: Eval(cp),
  replies: [
    for (final (uci, share, child) in replies)
      ReplyMove(
        move: MoveRef(uci: uci, san: uci),
        probability: share,
        child: child,
      ),
  ],
);

/// The opponent's position with a sound reply, leaving us [sound], and a
/// blunder played [share] of the time that leaves us [cp].
SearchNode trapAt(
  String name, {
  double share = 0.4,
  int cp = 200,
  int sound = 0,
}) => theirs(name, [
  ('sound', 1 - share, leaf('$name sound', sound)),
  ('blunder', share, leaf('$name blunder', cp)),
]);

void main() {
  group('at the edges', () {
    test('a blunder that leaves us exactly level is a trap', () {
      expect(trapsBelow(trapAt('level', cp: 0, sound: -100)).traps, 1);
    });

    test('a blunder exactly half a pawn past our best move is a trap', () {
      final tree = ours('root', [
        (
          'move',
          theirs('after', cp: 100, [
            ('sound', 0.6, leaf('sound', 50)),
            ('blunder', 0.4, leaf('blunder', 150)),
          ]),
        ),
      ]);
      expect(trapsBelow(tree).traps, 1);
    });

    test('a move of ours giving up exactly 300 is followed, more is not', () {
      SearchNode tree(int bestCp) => ours('root', [
        ('best', leaf('best', bestCp)),
        ('other', trapAt('other', cp: 400)),
      ]);
      expect(trapsBelow(tree(300)).traps, 1);
      expect(trapsBelow(tree(301)).traps, 0);
    });

    test('our best move is always followed, whatever it is worth', () {
      final tree = ours('root', [
        (
          'best',
          theirs('after', cp: 200, [
            ('sound', 0.6, leaf('sound', 200)),
            ('blunder', 0.4, leaf('blunder', 500)),
          ]),
        ),
      ]);
      expect(trapsBelow(tree).traps, 1);
    });
  });

  test('a position with no trap under it has none', () {
    final tree = theirs('root', [
      ('a', 0.6, leaf('a', 0)),
      ('b', 0.4, leaf('b', 20)),
    ]);
    expect(trapsBelow(tree), noTraps);
    expect(trapsBelow(leaf('leaf', 0)), noTraps);
  });

  test('the traps set at a position and in the lines below it are counted, '
      'and the likeliest is weighed by the replies on the way', () {
    final tree = theirs('root', [
      ('main', 0.5, ours('after main', [('ours', trapAt('deep'))])),
      ('side', 0.5, leaf('after side', 0)),
    ]);
    final scent = trapsBelow(tree);
    expect(scent.traps, 1);
    expect(scent.likeliest, closeTo(0.5 * 0.4, 1e-9));
    // Seen from the position after the reply it is nearer.
    final after = (tree as OpponentNode).replies.first.child;
    expect(trapsBelow(after).likeliest, closeTo(0.4, 1e-9));
  });

  test('traps under each of our moves are all counted; the likeliest is the '
      'likeliest under any one of them', () {
    final tree = ours('root', [
      ('one', trapAt('one', share: 0.3)),
      ('two', trapAt('two', share: 0.5)),
    ]);
    final scent = trapsBelow(tree);
    expect(scent.traps, 2);
    expect(scent.likeliest, closeTo(0.5, 1e-9));
  });

  test('a blunder that leaves us worse, or no better than our best move '
      'would have, is no trap', () {
    expect(trapsBelow(trapAt('losing', cp: -50, sound: -300)), noTraps);
    // Our best move here was worth 180: the blunder after the other move
    // only gets us back to 200, not half a pawn past it.
    final tree = ours('root', [
      ('best', leaf('best', 180)),
      ('other', trapAt('other', cp: 200)),
    ]);
    expect(trapsBelow(tree), noTraps);
    expect(
      trapsBelow(trapAt('other', cp: 200), bestBefore: 180),
      noTraps,
      reason: 'the same rule when the row is the move itself',
    );
    expect(trapsBelow(trapAt('other', cp: 200), bestBefore: 100).traps, 1);
  });

  test('a move of ours that gives up more than a line may is not followed', () {
    final tree = ours('root', [
      ('best', leaf('best', 400)),
      // 350 worse than the best: nothing we would play.
      (
        'bad',
        theirs('after bad', [
          ('sound', 0.5, leaf('sound', 50)),
          ('blunder', 0.5, leaf('blunder', 900)),
        ]),
      ),
    ]);
    expect(trapsBelow(tree), noTraps);
  });

  test('a subtree is counted once however often it is asked about', () {
    final deep = trapAt('deep');
    final tree = ours('root', [('move', deep)]);
    expect(identical(trapsBelow(tree), trapsBelow(tree)), isTrue);
  });
}

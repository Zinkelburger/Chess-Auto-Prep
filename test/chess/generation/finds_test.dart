import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/generation/eval.dart';
import 'package:chess_auto_prep/chess/generation/finds.dart';
import 'package:chess_auto_prep/chess/generation/search_node.dart';
import 'package:flutter_test/flutter_test.dart';

/// A made-up position called [name]: the rules never look at the chess.
Fen board(String name) => Fen('$name w - - 0 1');

SearchNode leaf(String name, int cp) =>
    HorizonNode(fen: board(name), evalForUs: Eval(cp));

SearchNode ours(String name, List<(String, SearchNode)> moves, {int cp = 0}) =>
    OurNode.over(
      fen: board(name),
      evalForUs: Eval(cp),
      candidates: [
        for (final (san, child) in moves)
          CandidateMove(
            move: MoveRef(uci: san, san: san),
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
    for (final (san, share, child) in replies)
      ReplyMove(
        move: MoveRef(uci: san, san: san),
        probability: share,
        child: child,
      ),
  ],
);

Iterable<Find> ofKind(List<Find> finds, FindKind kind) =>
    finds.where((f) => f.kind == kind);

void main() {
  test('a trap behind a move we would not choose is still found', () {
    // e4 is worth more, so a prepared line would only follow e4; exploring,
    // the trap after d4 is found too.
    final tree = ours('root', [
      ('e4', leaf('after e4', 100)),
      (
        'd4',
        theirs('after d4', [
          ('Nf6', 0.6, leaf('nf6', 0)),
          ('g5', 0.4, leaf('g5', 250)),
        ]),
      ),
    ]);

    final traps = ofKind(findsOf(tree), FindKind.trap).toList();

    expect(traps, hasLength(1));
    final trap = traps.single;
    expect(trap.sans.take(2), ['d4', 'g5']);
    expect(trap.ply, 2);
    expect(trap.keyPly, 1);
    expect(trap.fen, board('g5'));
    expect(trap.lossCp, 250);
    expect(trap.share, 0.4);
    expect(trap.evalCp, 250);
  });

  test('a reply that only fails to punish a worse move of ours is no trap', () {
    // After d4 their best is worth -100 to us and g5 lets us off to +20:
    // a blunder, but e4 was worth +50 anyway.
    final tree = ours('root', [
      ('e4', leaf('after e4', 50)),
      (
        'd4',
        theirs('after d4', cp: -100, [
          ('Nxe4', 0.6, leaf('punished', -100)),
          ('g5', 0.4, leaf('let off', 20)),
        ]),
      ),
    ]);

    expect(ofKind(findsOf(tree), FindKind.trap), isEmpty);
  });

  test('one move of ours that holds while the rest lose is an only move', () {
    final tree = ours('root', [
      ('Qd1', leaf('holds', 20)),
      ('Qe2', leaf('loses', -200)),
      ('Qf3', leaf('loses more', -400)),
    ]);

    final only = ofKind(findsOf(tree), FindKind.onlyMove).single;

    expect(only.fen, board('root'));
    expect(only.sans, ['Qd1']);
    expect(only.ply, 0);
    expect(only.lossCp, 220);
  });

  test('no only move when the second move also wins', () {
    final tree = ours('root', [
      ('Qd1', leaf('mates', 2000)),
      ('Qe2', leaf('wins', 700)),
    ]);

    expect(ofKind(findsOf(tree), FindKind.onlyMove), isEmpty);
  });

  test('their one saving reply, found less than half the time', () {
    final tree = theirs('root', [
      ('Kf8', 0.3, leaf('holds', 0)),
      ('Ke7', 0.7, leaf('loses', 300)),
    ]);

    final finds = findsOf(tree);
    final theirOnly = ofKind(finds, FindKind.theirOnlyMove).single;

    expect(theirOnly.sans, ['Kf8']);
    expect(theirOnly.share, 0.3);
    expect(theirOnly.lossCp, 300);
    // The likely reply that loses is a trap as well.
    expect(ofKind(finds, FindKind.trap), hasLength(1));
  });

  test('a move worse for the engine that scores better is practical', () {
    final tree = ours('root', [
      ('Nd5', leaf('engine best', 50)),
      (
        'h4',
        theirs('after h4', cp: 0, [
          ('g6', 0.5, leaf('g6', 300)),
          ('Nf6', 0.5, leaf('nf6', 300)),
        ]),
      ),
    ]);

    final practical = ofKind(findsOf(tree), FindKind.practical).single;

    expect(practical.sans, ['h4']);
    expect(practical.lossCp, 50);
  });

  test('a find seen from further back keeps its place in the line', () {
    final tree = ours('root', [
      ('Qd1', leaf('holds', 20)),
      ('Qe2', leaf('loses', -300)),
    ]);
    final only = ofKind(findsOf(tree), FindKind.onlyMove).single;

    final moved = only.after(['e4', 'e5']);

    expect(moved.sans, ['e4', 'e5', 'Qd1']);
    expect(moved.ply, 2);
    expect(moved.keyPly, 2);
    expect(moved.worth, only.worth);
  });

  test('finds are ranked by worth and capped', () {
    final tree = theirs('root', [
      ('a', 0.5, ours('a', [('x', leaf('ax', 0)), ('y', leaf('ay', -300))])),
      ('b', 0.5, ours('b', [('x', leaf('bx', 0)), ('y', leaf('by', -160))])),
    ]);

    final finds = findsOf(tree);
    expect(finds.first.worth, greaterThanOrEqualTo(finds.last.worth));
    expect(findsOf(tree, limit: 1), hasLength(1));
  });

  group('an only move that is an obvious capture', () {
    // After 1.e4 e5 2.Nf3 Nc6 3.Bc4 Nf6 4.Ng5 d5: the pawn that has just
    // come forward attacks the bishop.
    const twoKnights = Fen(
      'r1bqkb1r/ppp2ppp/2n2n2/3pp1N1/2B1P3/8/PPPP1PPP/RNBQK2R w KQkq - 0 5',
    );

    test('taking the piece that has just moved is obvious', () {
      expect(obviousCapture(twoKnights, 'e4d5', after: 'd7d5'), isTrue);
    });

    test('taking a piece worth more than the one that takes is obvious', () {
      // A knight on f7 takes the rook on h8.
      const fork = Fen(
        'r1b1k2r/ppppqNpp/2n2n2/2b1p3/2B1P3/8/PPPP1PPP/RNBQK2R w KQkq - 0 6',
      );
      expect(obviousCapture(fork, 'f7h8', after: 'd8e7'), isTrue);
    });

    test('a capture that gives up material, and a move that takes nothing, '
        'are not', () {
      // The knight takes the f7 pawn: a sacrifice, not a plain win.
      expect(obviousCapture(twoKnights, 'g5f7', after: 'd7d5'), isFalse);
      expect(obviousCapture(twoKnights, 'c4b3', after: 'd7d5'), isFalse);
    });

    test('a position that cannot be read is never called obvious', () {
      expect(obviousCapture(board('made up'), 'e4d5', after: 'd7d5'), isFalse);
    });

    test('an obvious recapture is not kept as an only move', () {
      SearchNode real(Fen fen, int cp) =>
          HorizonNode(fen: fen, evalForUs: Eval(cp));
      final tree = OpponentNode.over(
        fen: board('before d5'),
        evalForUs: const Eval(0),
        replies: [
          ReplyMove(
            move: const MoveRef(uci: 'd7d5', san: 'd5'),
            probability: 1,
            child: OurNode.over(
              fen: twoKnights,
              evalForUs: const Eval(0),
              candidates: [
                CandidateMove(
                  move: const MoveRef(uci: 'e4d5', san: 'exd5'),
                  child: real(board('after exd5'), 20),
                ),
                CandidateMove(
                  move: const MoveRef(uci: 'c4b3', san: 'Bb3'),
                  child: real(board('after Bb3'), -200),
                ),
              ],
            ),
          ),
        ],
      );
      expect(ofKind(findsOf(tree), FindKind.onlyMove), isEmpty);
    });
  });
}

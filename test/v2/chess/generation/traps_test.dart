import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/generation/draft_lines.dart';
import 'package:chess_auto_prep/v2/chess/generation/eval.dart';
import 'package:chess_auto_prep/v2/chess/generation/search_node.dart';
import 'package:chess_auto_prep/v2/chess/generation/traps.dart';
import 'package:flutter_test/flutter_test.dart';

/// A made-up position called [name]: the rules here never look at the
/// chess, only at which positions are the same.
Fen board(String name) => Fen('$name w - - 0 1');

/// A leaf the horizon stopped at, worth [cp] to us.
SearchNode leaf(String name, int cp) =>
    HorizonNode(fen: board(name), evalForUs: Eval(cp));

/// A leaf the search attached and never expanded.
SearchNode frontier(String name, int cp) =>
    FrontierNode(fen: board(name), evalForUs: Eval(cp));

/// Our position with [moves] as candidates, the first one the best by value.
SearchNode ours(String name, List<(String, SearchNode)> moves, {int cp = 0}) =>
    OurNode.over(
      fen: board(name),
      evalForUs: Eval(cp),
      candidates: [
        for (final (uci, child) in moves)
          CandidateMove(
            move: MoveRef(uci: uci, san: uci),
            child: child,
          ),
      ],
    );

/// The opponent's position with [replies] and their shares.
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

List<String> ucis(Iterable<DraftMove> moves) => [
  for (final m in moves) m.move.uci,
];

void main() {
  test('a likely reply that loses half a pawn or more is a trap', () {
    final tree = ours('root', [
      (
        'e2e4',
        theirs('after e4', [
          ('c7c5', 0.6, leaf('sicilian', 20)),
          (
            'f7f6',
            0.3,
            ours('after f6', [
              ('d1h5', theirs('after Qh5', [('g7g6', 1, leaf('g6', 400))])),
            ], cp: 350),
          ),
          ('a7a6', 0.1, leaf('a6', 300)),
        ]),
      ),
    ]);

    final traps = trapsOf(tree);

    expect(traps, hasLength(1));
    final trap = traps.single;
    expect(ucis(trap.toTrap), ['e2e4']);
    expect(trap.blunder.move.uci, 'f7f6');
    expect(trap.blunder.ours, isFalse);
    expect(ucis(trap.punishment), ['d1h5', 'g7g6']);
    expect(trap.punishment.first.ours, isTrue);
    expect(trap.share, 0.3);
    expect(trap.lossCp, 330);
    expect(trap.reach, 1);
    expect(trap.springs, 0.3);
    expect(trap.afterBest, const Eval(20));
    expect(trap.afterBlunder, const Eval(350));
    expect(ucis(trap.moves), ['e2e4', 'f7f6', 'd1h5', 'g7g6']);
  });

  test('the best reply, rare replies and small losses are not traps', () {
    final tree = theirs('root', [
      ('best', 0.5, leaf('best', -30)),
      ('small', 0.3, leaf('small', 10)),
      ('rare', 0.19, leaf('rare', 500)),
      ('rarer', 0.01, leaf('rarer', 900)),
    ]);

    expect(trapsOf(tree), isEmpty);
    expect(trapsOf(tree, minShare: 0.01).map((t) => t.blunder.move.uci), [
      'rare',
      'rarer',
    ]);
    expect(trapsOf(tree, minLossCp: 40).map((t) => t.blunder.move.uci), [
      'small',
    ]);
  });

  test('a deeper trap is reached through the opponent shares above it', () {
    final tree = theirs('root', [
      ('a', 0.5, leaf('a', 0)),
      (
        'b',
        0.5,
        ours('b', [
          (
            'ours',
            theirs('deep', [
              ('good', 0.6, leaf('good', 0)),
              ('bad', 0.4, leaf('bad', 200)),
            ]),
          ),
        ]),
      ),
    ]);

    final trap = trapsOf(tree).single;

    expect(ucis(trap.toTrap), ['b', 'ours']);
    expect(trap.reach, 0.5);
    expect(trap.springs, closeTo(0.2, 1e-12));
  });

  test('a blunder the search never answered has no punishment', () {
    final tree = theirs('root', [
      ('good', 0.7, leaf('good', 0)),
      ('bad', 0.3, frontier('bad', 300)),
    ]);

    final trap = trapsOf(tree).single;

    expect(trap.blunder.move.uci, 'bad');
    expect(trap.punishment, isEmpty);
  });

  test('the punishment follows our choice and their likeliest reply', () {
    SearchNode deep(int plies) => plies == 0
        ? leaf('end', 300)
        : plies.isEven
        ? ours('o$plies', [('m$plies', deep(plies - 1))], cp: 300)
        : theirs('t$plies', [
            ('x$plies', 0.3, deep(plies - 1)),
            ('y$plies', 0.7, deep(plies - 1)),
          ]);
    final tree = theirs('root', [
      ('good', 0.7, leaf('good', 0)),
      ('bad', 0.3, deep(8)),
    ]);

    final trap = trapsOf(tree, punishPlies: 4).single;

    expect(ucis(trap.punishment), ['m8', 'y7', 'm6', 'y5']);
    expect(
      [for (final m in trap.punishment) m.ours],
      [true, false, true, false],
    );
  });

  test('two roads to one blunder position are one trap, the likelier', () {
    SearchNode trapAt(String name) => theirs(name, [
      ('good', 0.5, leaf('good', 0)),
      ('bad', 0.5, leaf('same', 200)),
    ]);
    final tree = theirs('root', [
      ('p', 0.8, ours('p', [('x', trapAt('via p'))])),
      ('q', 0.2, ours('q', [('x', trapAt('via q'))])),
    ]);

    final traps = trapsOf(tree);

    expect(traps, hasLength(1));
    expect(ucis(traps.single.toTrap), ['p', 'x']);
  });

  test('traps are ranked by how often they spring times what they win', () {
    final tree = theirs('root', [
      ('best', 0.4, leaf('best', 0)),
      // Springs 0.3, wins 1000 counted as 300: 90.
      ('mate', 0.3, leaf('mate', 1000)),
      // Springs 0.3, wins 100: 30.
      ('slip', 0.3, leaf('slip', 100)),
    ]);
    final wider = theirs('root2', [
      ('best', 0.2, leaf('best2', 0)),
      // Springs 0.8, wins 200: 160.
      ('often', 0.8, leaf('often', 200)),
    ]);

    expect(trapsOf(tree).map((t) => t.blunder.move.uci), ['mate', 'slip']);
    expect(trapsOf(wider).single.blunder.move.uci, 'often');
  });

  test('ties are broken by the moves, the same way every run', () {
    final tree = theirs('root', [
      ('best', 0.4, leaf('best', 0)),
      ('zz', 0.3, leaf('zz', 100)),
      ('aa', 0.3, leaf('aa', 100)),
    ]);

    expect(trapsOf(tree).map((t) => t.blunder.move.uci), ['aa', 'zz']);
  });

  test('only our chosen move is walked', () {
    final trappy = theirs('trappy', [
      ('good', 0.5, leaf('good', 0)),
      ('bad', 0.5, leaf('bad', 500)),
    ]);
    final tree = ours('root', [
      ('chosen', leaf('chosen', 900)),
      ('other', trappy),
    ]);

    expect((tree as OurNode).chosen.move.uci, 'chosen');
    expect(trapsOf(tree), isEmpty);
  });

  test('a missed mate reports a capped loss rather than overflowing', () {
    final tree = theirs('root', [
      ('best', 0.5, leaf('best', -(mateBaseCp - 3))),
      ('mated', 0.5, leaf('mated', mateBaseCp - 1)),
    ]);

    final trap = trapsOf(tree).single;

    expect(trap.lossCp, trapLossCapCp);
    expect(trap.afterBlunder, const Eval(mateBaseCp - 1));
  });

  test('a position with one scored reply sets no trap', () {
    final tree = theirs('root', [('only', 1, leaf('only', 500))]);

    expect(trapsOf(tree), isEmpty);
  });

  group('withTraps', () {
    final tree = ours('root', [
      (
        'e2e4',
        theirs('after e4', [
          ('c7c5', 0.6, ours('sicilian', [('g1f3', leaf('nf3', 20))])),
          (
            'f7f6',
            0.3,
            ours('after f6', [
              ('d1h5', theirs('after Qh5', [('g7g6', 1, leaf('g6', 400))])),
            ], cp: 350),
          ),
          ('a7a6', 0.1, leaf('a6', 300)),
        ]),
      ),
    ]);

    test('adds each trap after the plan\'s own lines', () {
      final plan = planDraft([linesOf(tree).first]);
      final traps = trapsOf(tree);

      final withThem = withTraps(plan, traps);

      expect(withThem.lines, plan.lines + 1);
      expect(ucis(withThem.entries.last.line.moves), [
        'e2e4',
        'f7f6',
        'd1h5',
        'g7g6',
      ]);
      expect(withThem.entries.last.line.reach, closeTo(0.3, 1e-9));
    });

    test('does not write a trap a kept line already holds', () {
      final plan = planDraft(linesOf(tree));
      final traps = trapsOf(tree);

      expect(withTraps(plan, traps).lines, plan.lines);
    });
  });
}

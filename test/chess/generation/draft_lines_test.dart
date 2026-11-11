import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/generation/draft_chapter.dart';
import 'package:chess_auto_prep/chess/generation/draft_lines.dart';
import 'package:chess_auto_prep/chess/generation/eval.dart';
import 'package:chess_auto_prep/chess/generation/search_config.dart';
import 'package:chess_auto_prep/chess/generation/search_node.dart';
import 'package:chess_auto_prep/chess/openings.dart';
import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/chess/pgn/tree_edit.dart' hide positionOf;
import 'package:dartchess/dartchess.dart' show Position, Side;
import 'package:flutter_test/flutter_test.dart';

import 'search_harness.dart';

/// A line of [sans], space-separated, from the initial position, ours on
/// the even plies, each move worth [value]; the positions are real so
/// decisions are keyed the way a search keys them.
DraftLine line(String sans, {double reach = 1, double value = 0.5}) {
  final tree = lineTree(Fen.initial, sans.split(' '));
  final moves = <DraftMove>[];
  var fen = Fen.initial;
  var siblings = tree.children;
  var ply = 0;
  while (siblings.isNotEmpty) {
    final node = siblings.first;
    moves.add(
      DraftMove(
        move: MoveRef(uci: node.uci, san: node.san),
        before: fen.position,
        after: node.fen,
        value: value,
        ours: ply.isEven,
      ),
    );
    fen = node.fen;
    siblings = node.children;
    ply++;
  }
  return DraftLine(moves: moves, reach: reach);
}

/// A line of made-up moves on made-up boards, ours on the even plies: for
/// the rules about decisions, which never look at the chess.
DraftLine fake(List<String> ucis, {double reach = 1}) => DraftLine(
  moves: [
    for (final (i, uci) in ucis.indexed)
      DraftMove(
        move: MoveRef(uci: uci, san: uci),
        before: 'board $i',
        after: Fen.initial,
        value: 0.5,
        ours: i.isEven,
      ),
  ],
  reach: reach,
);

/// The draft of a Ruy Lopez line with a d3 sideline folded into it.
String ruyLopezDraft({
  Openings openings = Openings.none,
  Side side = Side.white,
}) {
  final kept = line('e4 e5 Nf3 Nc6 Bb5 a6 Ba4 Nf6 O-O', reach: 0.6, value: 0.6);
  final aside = line(
    'e4 e5 Nf3 Nc6 Bb5 a6 Ba4 Nf6 d3',
    reach: 0.1,
    value: 0.55,
  );
  final plan = planDraft([kept, aside]);
  expect(plan.entries.single.sidelines, hasLength(1));
  return draftChapterText(
    name: 'Main (draft)',
    side: side,
    rootFen: Fen.initial,
    rootMoves: const [],
    prefix: const [],
    plan: plan,
    created: DateTime(2026, 9, 22, 12),
    openings: openings,
  );
}

/// A one-move line of ours, [uci] played on the board called [before].
DraftLine oneMove(String uci, {required String before}) => DraftLine(
  moves: [
    DraftMove(
      move: MoveRef(uci: uci, san: uci),
      before: before,
      after: Fen.initial,
      value: 0.5,
      ours: true,
    ),
  ],
  reach: 1,
);

void main() {
  test('a draft names the user as the side it is for', () {
    expect(ruyLopezDraft(), contains('[White "Me"]\n[Black "Training"]'));
    expect(
      ruyLopezDraft(side: Side.black),
      contains('[White "Training"]\n[Black "Me"]'),
    );
  });

  group('lines of a searched tree', () {
    test('follow our chosen move and every answered reply, most reached '
        'first, ending on our move', () async {
      // The opponent has two replies to e4; only the likelier one gets
      // answered within the horizon of three.
      final root = positionOf(kingAndPawn);
      final afterE4 = afterUci(root, 'e2e4');
      final policy = TabulatedPolicy({
        afterE4.fen: {'e8d8': 0.7, 'e8f8': 0.3},
      });
      final result = await searchFrom(
        kingAndPawn,
        config: const SearchConfig(
          side: Side.white,
          horizonPlies: 3,
          lossLimitCp: 0,
          pins: {
            '4k3/8/8/8/8/8/4P3/4K3 w - -': {'e2e4'},
          },
        ),
        evaluator: matesForUs(),
        policy: policy,
      );
      final lines = linesOf(treeOf(result));
      expect(lines, hasLength(2));
      expect(lines.first.reach, 0.7);
      expect(lines.first.moves.map((m) => m.move.san).toList(), [
        'e4',
        'Kd8',
        anything,
      ]);
      expect(lines.first.moves.last.ours, isTrue);
      expect(lines.first.moves[1].ours, isFalse, reason: 'Kd8 is theirs');
      expect(lines.last.reach, 0.3);
      expect(lines.last.moves.map((m) => m.move.san), ['e4', 'Kf8', anything]);
    });
  });

  group('planning the draft', () {
    test('a line whose decisions the chapter already makes is left out', () {
      final e4e5 = line('e4 e5 Nf3');
      final plan = planDraft([e4e5], known: e4e5.decisions);
      expect(plan.lines, 0);
    });

    test('lines that teach different decisions are all kept', () {
      final plan = planDraft([
        line('e4 e5 Nf3', reach: 0.5),
        line('e4 c5 Nf3', reach: 0.3),
        line('e4 e6 d4', reach: 0.2),
      ]);
      expect(plan.lines, 3);
      expect(plan.entries.expand((e) => e.sidelines), isEmpty);
    });
  });

  group('near-copies', () {
    // Sixteen plies, ours on the even ones: eight decisions.
    final base = [for (var i = 0; i < 16; i++) 'm$i'];

    test('a near-copy that only goes on past a kept line folds in where '
        'that line ends', () {
      final plan = planDraft([
        fake(base, reach: 0.5),
        fake([...base, 'm16', 'm17'], reach: 0.4),
      ]);
      final (divergeAt, _) = plan.entries.single.sidelines.single;
      expect(divergeAt, 16);
    });

    test('a near-copy that shares only the first move folds in after it', () {
      final plan = planDraft([
        fake(base, reach: 0.5),
        fake(['m0', 'other', ...base.sublist(2, 7)], reach: 0.4),
      ]);
      final (divergeAt, _) = plan.entries.single.sidelines.single;
      expect(divergeAt, 1);
    });

    test('a near-copy that leaves at the first move shares nothing and is '
        'dropped', () {
      final plan = planDraft([
        fake(base, reach: 0.5),
        fake(['other', ...base.skip(1), 'm16', 'm17'], reach: 0.4),
      ]);
      expect(plan.entries.single.sidelines, isEmpty);
    });

    test('a near-copy folds into the kept line it shares the longest '
        'prefix with, as a short sideline', () {
      // Five decisions, four of them already taught: too little that is
      // new, so the line hangs off its host at the move where they part.
      final host = line('e4 e5 Nf3 Nc6 Bb5 a6 Ba4 Nf6 O-O', reach: 0.4);
      final copy = line('e4 e5 Nf3 Nc6 Bb5 a6 Ba4 b5 Bb3', reach: 0.2);
      final plan = planDraft([host, copy]);
      expect(plan.lines, 1);
      final (divergeAt, folded) = plan.entries.single.sidelines.single;
      expect(divergeAt, 7);
      expect(folded, same(copy));
    });

    test('a line that teaches enough of its own is a line, however much of '
        'its start it shares', () {
      final host = line('e4 e5 Nf3 Nc6 Bb5 a6 Ba4 Nf6 O-O', reach: 0.4);
      final longer = line(
        'e4 e5 Nf3 Nc6 Bb5 a6 Ba4 Nf6 O-O Be7 Re1 b5 Bb3 d6 c3 O-O h3',
        reach: 0.3,
      );
      // Four new decisions out of nine.
      final plan = planDraft([host, longer]);
      expect(plan.lines, 2);
    });

    test('a near-copy with a long tail, or no shared prefix, is dropped', () {
      final host = fake([for (var i = 0; i < 40; i++) 'm$i'], reach: 0.4);
      // Sixteen of twenty decisions already taught, and eight plies of tail:
      // too little that is new for a line, too long for a sideline.
      final longTail = fake([
        for (var i = 0; i < 32; i++) 'm$i',
        for (var i = 32; i < 40; i++) 'x$i',
      ], reach: 0.3);
      // The same, sharing no first move: nothing to hang off.
      final elsewhere = fake([
        'y0',
        for (var i = 1; i < 40; i++) 'm$i',
      ], reach: 0.2);
      final plan = planDraft([host, longTail, elsewhere]);
      expect(plan.lines, 1);
      expect(plan.entries.single.sidelines, isEmpty, reason: 'both dropped');
    });
  });

  group('the cap', () {
    test('no more than the cap are kept; the rest fold or drop', () {
      // Every line differs at the root and shares no prefix: past the cap,
      // each has nothing to hang off.
      final root = positionOf(Fen.initial.value);
      final ucis = [
        for (final entry in root.legalMoves.entries)
          for (final to in entry.value.squares) '${entry.key.name}${to.name}',
      ];
      expect(ucis.length, 20);
      final many = [
        for (var i = 0; i < 6; i++)
          for (final uci in ucis) oneMove(uci, before: 'board $i'),
      ];
      final plan = planDraft(many);
      expect(plan.lines, DraftPlan.cap);
      expect(
        plan.entries.expand((e) => e.sidelines),
        isEmpty,
        reason: 'the twenty past the cap have nothing to hang off',
      );
    });
  });

  group('traps in the draft', () {
    test('a reply the trap rule marks is written with ?, the rest plain', () {
      final afterE4 = afterUci(positionOf(Fen.initial.value), 'e2e4');
      Fen fenOf(Position position) => Fen(position.fen);
      SearchNode answered(Position after, int cp) => OurNode.over(
        fen: fenOf(after),
        evalForUs: Eval(cp),
        candidates: [
          CandidateMove(
            move: const MoveRef(uci: 'g1f3', san: 'Nf3'),
            child: HorizonNode(
              fen: fenOf(afterUci(after, 'g1f3')),
              evalForUs: Eval(cp),
            ),
          ),
        ],
      );
      final tree = OpponentNode.over(
        fen: fenOf(afterE4),
        evalForUs: const Eval(0),
        replies: [
          ReplyMove(
            move: const MoveRef(uci: 'e7e5', san: 'e5'),
            probability: 0.7,
            child: answered(afterUci(afterE4, 'e7e5'), 0),
          ),
          // Played 30%, and a pawn worse for them than e5.
          ReplyMove(
            move: const MoveRef(uci: 'f7f6', san: 'f6'),
            probability: 0.3,
            child: answered(afterUci(afterE4, 'f7f6'), 100),
          ),
        ],
      );
      final lines = linesOf(tree);
      expect([for (final l in lines) l.moves.first.trap], [false, true]);
      final trap = draftTree(
        DraftEntry(line: lines.last),
        rootFen: fenOf(afterE4),
      );
      expect(trap.children.single.san, 'f6');
      expect(trap.children.single.nags, [2]);
      final plain = draftTree(
        DraftEntry(line: lines.first),
        rootFen: fenOf(afterE4),
      );
      expect(plain.children.single.nags, isEmpty);
    });
  });

  group('writing the draft', () {
    test('every move carries its tokens, the first its reach, and the '
        'heading says Draft', () {
      final text = ruyLopezDraft();
      expect(text, startsWith('// Main (draft)\n// Draft\n// Color: White\n'));
      expect(text, contains('[Event "Main (draft)"]'));
      expect(text, contains('[CumProb "0.6000"]'));
      expect(text, contains('[Annotator "Chess Auto Prep"]'));
      expect(
        text,
        contains(
          '1. e4 {[%cumProb 60.0%] [%expectimax +1.10] [%score 60.0%]} '
          'e5 {[%expectimax +1.10] [%score 60.0%]} '
          '2. Nf3 {[%expectimax +1.10] [%score 60.0%]}',
        ),
      );
      expect(
        text,
        contains(
          '5. O-O {[%expectimax +1.10] [%score 60.0%]} '
          '(5. d3 {[%expectimax +0.54] [%score 55.0%]}) *',
        ),
      );
    });

    test('a line is named after the last position of its main line the '
        'opening book names', () {
      final book = Openings.parse([
        'eco\tname\tpgn\n'
            'C60\tRuy Lopez\t1. e4 e5 2. Nf3 Nc6 3. Bb5\n'
            'C78\tRuy Lopez: Morphy Defense\t'
            '1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 Nf6 5. O-O\n',
      ]);
      final text = ruyLopezDraft(openings: book);
      expect(text, contains('[Event "Ruy Lopez: Morphy Defense"]'));
      expect(text, contains('[ECO "C78"]'));
    });

    test('the chapter reads back as one game with its sideline', () async {
      final chapter = await readChapter(
        name: 'Main (draft)',
        text: ruyLopezDraft(),
      );
      expect(chapter.side, Side.white);
      expect(chapter.gameCount, 1);
      expect(chapter.tree.children.single.san, 'e4');
      final nf6 = NodePath.of(List.filled(8, 0));
      expect(chapter.tree.nodeAt(nf6)!.san, 'Nf6');
      expect(chapter.tree.nodeAt(nf6)!.children, hasLength(2));
    });
  });

  group('draft trees', () {
    test('sidelines that leave at the same move and share their start are '
        'one branch, not two copies of the shared move', () {
      final kept = line('e4 e5 Nf3 Nc6 Bb5');
      final bishop = line('e4 e5 Bc4 Nc6');
      final bishopBc5 = line('e4 e5 Bc4 Bc5');
      final tree = draftTree(
        DraftEntry(line: kept, sidelines: [(2, bishop), (2, bishopBc5)]),
        rootFen: Fen.initial,
      );
      final e5 = tree.nodeAt(NodePath.of([0, 0]))!;
      expect(e5.children.map((n) => n.san), ['Nf3', 'Bc4']);
      expect(e5.children.last.children.map((n) => n.san), ['Nc6', 'Bc5']);
    });
  });

  group('the prefix', () {
    test('lines are rooted at the chapter, through the prefix to the board, '
        'so they can be dropped into it', () {
      final prefix = lineTree(Fen.initial, ['d4', 'd5']);
      final searchRoot = prefix.nodeAt(NodePath.of([0, 0]))!.fen;
      final searched = DraftLine(
        moves: [
          DraftMove(
            move: const MoveRef(uci: 'c2c4', san: 'c4'),
            before: searchRoot.position,
            after: lineTree(Fen.initial, [
              'd4',
              'd5',
              'c4',
            ]).nodeAt(NodePath.of([0, 0, 0]))!.fen,
            value: 0.55,
            ours: true,
          ),
        ],
        reach: 1,
      );
      final tree = draftTree(
        DraftEntry(line: searched),
        rootFen: Fen.initial,
        prefix: prefix.lineTo(NodePath.of([0, 0])),
      );
      expect(mainlineSans(tree), ['d4', 'd5', 'c4']);
      expect(
        tree.children.single.comment,
        isNull,
        reason: 'the prefix is bare',
      );
      expect(
        tree.nodeAt(NodePath.of([0, 0, 0]))!.comment,
        contains('[%expectimax'),
      );
    });
  });

  group('reading a chapter', () {
    test('a chapter\'s decisions are read off its tree, castling in '
        'both spellings', () async {
      final chapter = await readChapter(
        name: 'Main',
        text:
            '// Color: White\n\n[Event "x"]\n[Result "*"]\n\n'
            '1. e4 e5 2. Nf3 Nc6 3. Bc4 Bc5 4. O-O *\n',
      );
      final decisions = chapterDecisions(chapter);
      expect(decisions, contains('${Fen.initial.position}|e2e4'));
      expect(decisions.where((d) => d.endsWith('|e1g1')), hasLength(1));
      expect(decisions.where((d) => d.endsWith('|e1h1')), hasLength(1));
    });
  });

  group('expectimax text', () {
    test('is the centipawn equivalent in pawns, capped short of a mate', () {
      expect(expectimaxText(0.5), '+0.00');
      expect(expectimaxText(0.6), '+1.10');
      expect(expectimaxText(0.4), '-1.10');
      expect(expectimaxText(1), '+89.99');
      expect(expectimaxText(0), '-89.99');
      expect(expectimaxIn('words [%expectimax +0.42] [%score 55%]'), '+0.42');
      expect(expectimaxIn('[%eval 0.3]'), isNull);
      expect(expectimaxIn(null), isNull);
    });
  });

  group('continuation', () {
    test('a line goes on with the engine\'s best play, uncommented, '
        'cut where it stops being legal', () {
      final kept = line('e4 e5 Nf3', value: 0.6);
      final end = kept.moves.last.after;
      final plan = withContinuations(
        DraftPlan(entries: [DraftEntry(line: kept)]),
        {
          end.position: [
            'b8c6',
            'f1b5',
            'a7a6',
            'b5a4',
            'g8f6',
            'e1g1',
            'f8e7',
          ],
        },
      );
      final entry = plan.entries.single;
      expect(entry.continuation.map((m) => m.san), [
        'Nc6',
        'Bb5',
        'a6',
        'Ba4',
        'Nf6',
        'O-O',
      ], reason: 'six plies at most');
      final tree = draftTree(entry, rootFen: Fen.initial);
      expect(mainlineSans(tree), [
        'e4', 'e5', 'Nf3', 'Nc6', 'Bb5', 'a6', 'Ba4', 'Nf6', 'O-O', //
      ]);
      var node = tree.children.single;
      final comments = <String?>[];
      while (true) {
        comments.add(node.comment);
        if (node.children.isEmpty) break;
        node = node.children.first;
      }
      expect(comments.take(3), everyElement(contains('[%expectimax')));
      expect(comments.skip(3), everyElement(isNull));

      final illegal = withContinuations(
        DraftPlan(entries: [DraftEntry(line: kept)]),
        {
          end.position: ['b8c6', 'e1g1'],
        },
      );
      expect(illegal.entries.single.continuation.map((m) => m.san), ['Nc6']);
    });

    test('a line with no best line for its end is left as it is', () {
      final kept = line('e4 e5 Nf3');
      final plan = DraftPlan(entries: [DraftEntry(line: kept)]);
      expect(lineEnds(plan), {kept.moves.last.after});
      final same = withContinuations(plan, const {});
      expect(same.entries.single.continuation, isEmpty);
    });
  });

  group('one move per position', () {
    Fen fenOf(Position position) => Fen(position.fen);
    final start = positionOf(Fen.initial.value);

    /// Our position [at] with [moves] as candidates, best by value first,
    /// each leading to a leaf worth what it says.
    OurNode choice(Position at, List<(String, String, int)> moves) =>
        OurNode.over(
          fen: fenOf(at),
          evalForUs: const Eval(0),
          candidates: [
            for (final (uci, san, cp) in moves)
              CandidateMove(
                move: MoveRef(uci: uci, san: san),
                child: HorizonNode(
                  fen: fenOf(afterUci(at, uci)),
                  evalForUs: Eval(cp),
                ),
              ),
          ],
        );

    test('a position two move orders reach is answered with the move of '
        'the likelier line', () {
      // 1.Nf3 Nf6 2.Nc3 and 1.Nc3 Nf6 2.Nf3 are not searched here: the two
      // paths are built by hand to end on the same position, where the
      // search, valuing each path on its own, chose differently.
      final shared = afterUci(afterUci(start, 'e2e4'), 'e7e5');
      final likely = choice(shared, [('g1f3', 'Nf3', 60), ('b1c3', 'Nc3', 40)]);
      final rare = choice(shared, [('b1c3', 'Nc3', 70), ('g1f3', 'Nf3', 30)]);
      final tree = OpponentNode.over(
        fen: fenOf(start),
        evalForUs: const Eval(0),
        replies: [
          ReplyMove(
            move: const MoveRef(uci: 'x1', san: 'x1'),
            probability: 0.7,
            child: likely,
          ),
          ReplyMove(
            move: const MoveRef(uci: 'x2', san: 'x2'),
            probability: 0.3,
            child: rare,
          ),
        ],
      );
      expect(likely.chosen.move.uci, 'g1f3');
      expect(rare.chosen.move.uci, 'b1c3');

      final decided = draftDecisions(tree);
      expect(decided[fenOf(shared).position], 'g1f3');
      final lines = linesOf(tree, decided: decided);
      expect([for (final l in lines) l.moves.last.move.uci], ['g1f3', 'g1f3']);
      // Without the decisions each path keeps its own choice.
      expect(
        [for (final l in linesOf(tree)) l.moves.last.move.uci],
        ['g1f3', 'b1c3'],
      );
    });

    test('where the chapter already plays a move the search looked at, the '
        'line follows the chapter', () {
      final at = afterUci(afterUci(start, 'e2e4'), 'e7e5');
      final node = choice(at, [('g1f3', 'Nf3', 60), ('f1c4', 'Bc4', 40)]);
      final decided = draftDecisions(
        node,
        pins: {
          fenOf(at).position: {'f1c4'},
        },
      );
      expect(
        linesOf(node, decided: decided).single.moves.single.move.uci,
        'f1c4',
      );
      // A move the search never looked at cannot be followed.
      final unknown = draftDecisions(
        node,
        pins: {
          fenOf(at).position: {'d2d4'},
        },
      );
      expect(
        linesOf(node, decided: unknown).single.moves.single.move.uci,
        'g1f3',
      );
    });
  });

  group('the order of a draft', () {
    test('lines that start on the opponent\'s move group by that move', () {
      // From a position with the opponent to move: each line starts with
      // their reply, and teaches decisions of its own.
      DraftLine theirs(String reply, String ours, double reach) => DraftLine(
        moves: [
          DraftMove(
            move: MoveRef(uci: reply, san: reply),
            before: 'start',
            after: Fen.initial,
            value: 0.5,
            ours: false,
          ),
          DraftMove(
            move: MoveRef(uci: ours, san: ours),
            before: 'after $reply',
            after: Fen.initial,
            value: 0.5,
            ours: true,
          ),
        ],
        reach: reach,
      );
      final plan = planDraft([
        theirs('a', 'x', 0.3),
        theirs('b', 'y', 0.25),
        theirs('a', 'z', 0.2),
      ]);
      expect([for (final e in plan.entries) e.line.ucis.last], ['x', 'z', 'y']);
    });

    test('lines that start with the same reply are kept together, the reply '
        'games take most often first', () {
      // Ours on the even plies: the first reply is the second move.
      final plan = planDraft([
        fake(['a', 'r1', 'b', 's1', 'c'], reach: 0.30),
        fake(['a', 'r2', 'd', 't1', 'e'], reach: 0.25),
        fake(['a', 'r2', 'd', 't2', 'f'], reach: 0.20),
        fake(['a', 'r1', 'b', 's2', 'g'], reach: 0.05),
      ]);
      expect(
        [for (final entry in plan.entries) entry.line.ucis.join(' ')],
        [
          // r2 is met in 45% of games, r1 in 35%.
          'a r2 d t1 e',
          'a r2 d t2 f',
          'a r1 b s1 c',
          'a r1 b s2 g',
        ],
      );
    });
  });

  group('what a trap says', () {
    test('a trap\'s reply carries why it is marked, in words, before its '
        'tokens', () {
      const trap = DraftMove(
        move: MoveRef(uci: 'f7f6', san: 'f6'),
        before: 'board',
        after: Fen.initial,
        value: 0.6,
        ours: false,
        share: 0.44,
        trapLossCp: 90,
      );
      expect(trapNote(trap), 'Trap: played 44%, loses 0.9.');
      final tree = draftTree(
        const DraftEntry(line: DraftLine(moves: [trap], reach: 1)),
        rootFen: Fen.initial,
      );
      expect(
        tree.children.single.comment,
        startsWith('Trap: played 44%, loses 0.9. [%cumProb'),
      );
      expect(tree.children.single.nags, [2]);
    });

    test('any other move says nothing', () {
      expect(trapNote(line('e4').moves.single), isNull);
    });
  });

  group('line names', () {
    test('the family most lines share is left off each of them', () {
      const names = [
        'Italian Game: Two Knights Defense',
        'Italian Game: Classical Variation',
        'Scotch Game: Benima Defense',
        null,
      ];
      final family = sharedFamily(names);
      expect(family, 'Italian Game');
      expect(
        [for (final name in names.nonNulls) withoutFamily(name, family)],
        [
          'Two Knights Defense',
          'Classical Variation',
          'Scotch Game: Benima Defense',
        ],
      );
    });

    test(
      'one line, or lines of different openings, keep their whole names',
      () {
        expect(sharedFamily(const ['Ruy Lopez: Morphy Defense']), isNull);
        expect(
          sharedFamily(const [
            'Ruy Lopez: Morphy Defense',
            'Italian Game: Classical Variation',
          ]),
          isNull,
        );
        expect(withoutFamily('Italian Game', 'Italian Game'), 'Italian Game');
      },
    );
  });
}

import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/generation/draft_chapter.dart';
import 'package:chess_auto_prep/v2/chess/generation/draft_lines.dart';
import 'package:chess_auto_prep/v2/chess/generation/search_config.dart';
import 'package:chess_auto_prep/v2/chess/generation/search_node.dart';
import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/chess/pgn/tree_edit.dart' hide positionOf;
import 'package:dartchess/dartchess.dart' show Side;
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
String ruyLopezDraft() {
  final kept = line('e4 e5 Nf3 Nc6 Bb5 a6 Ba4 Nf6 O-O', reach: 0.6, value: 0.6);
  final aside = line(
    'e4 e5 Nf3 Nc6 Bb5 a6 Ba4 Nf6 d3',
    reach: 0.1,
    value: 0.55,
  );
  final plan = planDraft([kept, aside]);
  expect(plan.folded, 1);
  return draftChapterText(
    name: 'Main (draft)',
    side: Side.white,
    rootFen: Fen.initial,
    rootMoves: const [],
    prefix: const [],
    plan: plan,
    created: DateTime(2026, 9, 22, 12, 0, 0),
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
      expect(lines.last.reach, 0.3);
      expect(lines.last.moves.map((m) => m.move.san), ['e4', 'Kf8', anything]);
    });
  });

  group('planning the draft', () {
    test('a line whose decisions the chapter already makes is left out', () {
      final e4e5 = line('e4 e5 Nf3');
      final plan = planDraft([e4e5], known: e4e5.decisions);
      expect(plan.lines, 0);
      expect(plan.alreadyThere, 1);
    });

    test('lines that teach different decisions are all kept', () {
      final plan = planDraft([
        line('e4 e5 Nf3', reach: 0.5),
        line('e4 c5 Nf3', reach: 0.3),
        line('e4 e6 d4', reach: 0.2),
      ]);
      expect(plan.lines, 3);
      expect(plan.folded, 0);
    });
  });

  group('near-copies', () {
    test('a near-copy folds into the kept line it shares the longest '
        'prefix with, as a short sideline', () {
      // Five decisions, four of them already taught: too little that is
      // new, so the line hangs off its host at the move where they part.
      final host = line('e4 e5 Nf3 Nc6 Bb5 a6 Ba4 Nf6 O-O', reach: 0.4);
      final copy = line('e4 e5 Nf3 Nc6 Bb5 a6 Ba4 b5 Bb3', reach: 0.2);
      final plan = planDraft([host, copy]);
      expect(plan.lines, 1);
      expect(plan.folded, 1);
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
      expect(plan.dropped, 2);
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
      expect(plan.dropped, 20);
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
}

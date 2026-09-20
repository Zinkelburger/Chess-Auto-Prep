import 'dart:math';

import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/pgn/chapter_line.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_text.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/chess/pgn/pgn_reader.dart';
import 'package:chess_auto_prep/v2/chess/pgn/rewrite_gate.dart';
import 'package:chess_auto_prep/v2/chess/pgn/tree_edit.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

/// Comment bodies a file may really hold. None holds a `}`, which no PGN
/// comment can.
const _comments = [
  'A plain note.',
  '[%eval 0.42] [%clk 0:12:03]',
  'Mixed prose [%cal Ge2e4,Rd7d5] and more',
  'braces { inside are text',
  'half a bracket ] and a percent 46.4%',
  '½ → ∞ ♞ and a private glyph ',
  'line one\nline two',
  ' padded ',
  'a; semicolon',
];

const _nags = [1, 2, 3, 4, 5, 6, 13, 14, 16, 132, 146];

/// Every legal move of [position], queen promotions included.
List<Move> legalMovesOf(Position position) {
  final moves = <Move>[];
  for (final entry in position.legalMoves.entries) {
    for (final to in entry.value.squares) {
      final plain = NormalMove(from: entry.key, to: to);
      if (position.isLegal(plain)) {
        moves.add(plain);
        continue;
      }
      final promoted = NormalMove(
        from: entry.key,
        to: to,
        promotion: Role.queen,
      );
      if (position.isLegal(promoted)) moves.add(promoted);
    }
  }
  return moves;
}

/// A tree of real moves from [fen], [plies] deep, branching where [random]
/// says so, with comments and annotations on about half the moves.
///
/// Only a move that starts a variation gets a note before it: that is the
/// one place PGN has to write one. See [MoveNode.startingComment].
List<MoveNode> growTree(Random random, Fen fen, int plies) {
  if (plies == 0) return const [];
  final moves = legalMovesOf(positionOf(fen)!)..shuffle(random);
  if (moves.isEmpty) return const [];
  final siblings = 1 + (random.nextInt(4) == 0 ? random.nextInt(2) + 1 : 0);
  return [
    for (final (index, move) in moves.take(min(siblings, moves.length)).indexed)
      _decorated(
        random,
        moveNode(fen, move)!,
        plies,
        startsVariation: index > 0,
      ),
  ];
}

MoveNode _decorated(
  Random random,
  MoveNode node,
  int plies, {
  required bool startsVariation,
}) => node.copyWith(
  startingComment: startsVariation && random.nextInt(3) == 0
      ? _pick(random, _comments)
      : null,
  comment: random.nextInt(2) == 0 ? _pick(random, _comments) : null,
  nags: random.nextInt(4) == 0
      ? [for (var i = 0; i <= random.nextInt(2); i++) _pick(random, _nags)]
      : const [],
  children: growTree(random, node.fen, plies - 1),
);

T _pick<T>(Random random, List<T> from) => from[random.nextInt(from.length)];

void main() {
  test('a tree written and read again is the same tree', () {
    for (var seed = 0; seed < 40; seed++) {
      final random = Random(seed);
      final tree = GameTree(
        rootFen: Fen.initial,
        rootComment: random.nextInt(3) == 0 ? _pick(random, _comments) : null,
        children: growTree(random, Fen.initial, 6),
      );
      const tags = [PgnTag('Event', 'Property'), PgnTag('Result', '*')];
      final line = ChapterLine(
        tags: tags,
        tree: tree,
        text: '',
        trailer: '',
        terminator: '*',
        separator: '\n',
      );
      final rewrite = rewritten(line, tree);
      expect(
        rewrite is LineRewritten ? null : (rewrite as LineRefused).reason,
        isNull,
        reason: 'seed $seed',
      );
      final text = (rewrite as LineRewritten).line.text;
      expect(readGame(text).issues, isEmpty, reason: 'seed $seed');
      // Written a second time from what reading gave: the same bytes, so a
      // game cannot drift a little further on every save.
      final again = readGame(text);
      expect(
        writeGameText(
          again.tags,
          again.tree!,
          terminator: again.terminator,
          separator: again.separator,
        ),
        text,
        reason: 'seed $seed',
      );
    }
  });
}

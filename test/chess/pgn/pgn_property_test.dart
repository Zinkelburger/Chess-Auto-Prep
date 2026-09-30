import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/pgn/chapter_line.dart';
import 'package:chess_auto_prep/chess/pgn/game_text.dart';
import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/chess/pgn/pgn_reader.dart';
import 'package:chess_auto_prep/chess/pgn/rewrite_gate.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/gen/tree_gen.dart';
import '../../support/props.dart';

void main() {
  test('a tree written and read again is the same tree', () {
    for (var seed = 0; seed < 40; seed++) {
      final random = Rand(seed);
      final tree = GameTree(
        rootFen: Fen.initial,
        rootComment: random.nextInt(3) == 0 ? treeComment(random) : null,
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

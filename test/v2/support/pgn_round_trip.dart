import 'package:chess_auto_prep/v2/chess/pgn/chapter_line.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_text.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/chess/pgn/pgn_reader.dart';
import 'package:chess_auto_prep/v2/chess/pgn/rewrite_gate.dart';
import 'package:flutter_test/flutter_test.dart';

/// [read] as one game of a chapter, so a test asks the same gate the app
/// asks rather than a second copy of it.
ChapterLine lineOf(GameRead read, String text) => ChapterLine(
  tags: read.tags,
  tree: read.tree,
  text: text,
  trailer: '',
  terminator: read.terminator,
  separator: read.separator,
  issues: read.issues,
);

/// [game] written again from what reading it gave.
String written(GameRead read) => writeGameText(
  read.tags,
  read.tree!,
  terminator: read.terminator,
  separator: read.separator,
);

/// The reason the gate gives for refusing to write [game] again with
/// [tree], or null when it allows it.
String? refusal(String game, [GameTree? tree]) {
  final read = readGame(game);
  final rewrite = rewritten(lineOf(read, game), tree ?? read.tree!);
  return switch (rewrite) {
    LineRewritten() => null,
    LineRefused(:final reason) => reason,
  };
}

/// Asserts that [game] survives being read and written: the rewrite gate
/// allows it, and writing the game a second time gives the same bytes as the
/// first, so an edit never drifts a game a little further each time.
void expectRoundTrip(String game) {
  final read = readGame(game);
  expect(read.issues, isEmpty, reason: 'reading $game');
  expect(refusal(game), isNull, reason: 'the rewrite gate refused $game');
  final once = written(read);
  expect(written(readGame(once)), once, reason: 'writing $game twice');
}

/// Asserts that [game] round-trips and comes back byte for byte.
void expectExactRoundTrip(String game) {
  expectRoundTrip(game);
  expect(written(readGame(game)), game);
}

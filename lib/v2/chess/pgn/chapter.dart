import 'dart:convert';

import 'package:dartchess/dartchess.dart';

import '../fen.dart';
import 'game_tree.dart';
import 'pgn_reader.dart';
import 'tree_merge.dart';

/// A repertoire chapter: every game in its file merged into one tree.
///
/// A chapter file is a multi-game PGN where each game is one line, all from
/// the same starting position, with a `// Color: Black` comment line above
/// the first game saying whose repertoire it is. Games that start somewhere
/// else are counted in [skippedGames] rather than silently dropped.
final class Chapter {
  const Chapter({
    required this.name,
    required this.side,
    required this.tree,
    required this.gameCount,
    required this.skippedGames,
    required this.issues,
  });

  final String name;

  /// The side the repertoire is for; also the board orientation.
  final Side side;

  final GameTree tree;

  /// Games merged into [tree].
  final int gameCount;

  /// Games left out because their root position differs from the first one.
  final int skippedGames;

  final List<PgnIssue> issues;
}

Chapter parseChapter({required String name, required String text}) {
  final side = _sideFromHeaderLines(text);
  final read = readPgn(_withoutHeaderLines(text));
  final first = read.games.firstOrNull;
  if (first == null) {
    return Chapter(
      name: name,
      side: side,
      tree: const GameTree(rootFen: Fen.initial),
      gameCount: 0,
      skippedGames: 0,
      issues: read.issues,
    );
  }
  final root = first.tree.rootFen;
  final sameRoot = read.games.where((g) => g.tree.rootFen == root);
  final children = sameRoot.fold(
    const <MoveNode>[],
    (merged, game) => mergeForests(merged, game.tree.children),
  );
  return Chapter(
    name: name,
    side: side,
    tree: GameTree(
      rootFen: root,
      rootComment: first.tree.rootComment,
      children: children,
    ),
    gameCount: sameRoot.length,
    skippedGames: read.games.length - sameRoot.length,
    issues: read.issues,
  );
}

/// `// Color: Black` above the first tag reads as Black; anything else,
/// including no line at all, is White. The old app wrote it that way and
/// reads it the same way.
Side _sideFromHeaderLines(String text) {
  for (final line in _headerLines(text)) {
    if (line.startsWith('// Color:')) {
      final color = line.substring('// Color:'.length).trim().toLowerCase();
      return color == 'black' ? Side.black : Side.white;
    }
  }
  return Side.white;
}

/// The `//` lines before the first `[` tag, which are this app's metadata
/// and not PGN. The PGN parser would otherwise read them as junk tokens.
Iterable<String> _headerLines(String text) sync* {
  for (final line in const LineSplitter().convert(text)) {
    final trimmed = line.trim();
    if (trimmed.startsWith('[')) return;
    if (trimmed.startsWith('//')) yield trimmed;
  }
}

String _withoutHeaderLines(String text) {
  final lines = const LineSplitter().convert(text);
  final firstTag = lines.indexWhere((line) => line.trim().startsWith('['));
  if (firstTag <= 0) return text;
  return lines.skip(firstTag).join('\n');
}

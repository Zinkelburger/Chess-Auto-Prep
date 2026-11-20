/// Whole games built through the app's model for the preservation laws: a
/// tree of real moves from [treeRoots] with a chain of variations nested up
/// to fifty deep under its main line, and a header block of known, unknown,
/// escaped and non-ASCII tags, each ending the way a file in the wild ends
/// it. A case is its seed and three sizes, so a failure shrinks by size and
/// replays from the seed.
library;

import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/pgn/game_text.dart';
import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/chess/pgn/tree_edit.dart';

import '../props.dart';
import 'tree_gen.dart';

/// One generated game: the [seed] every choice is drawn from, how many
/// plies its tree grows ([plies]), how deep the variations under its main
/// line nest ([depth]) and how many tags beyond `[Event]` it carries
/// ([tags]).
final class GameCase {
  const GameCase(this.seed, {this.plies = 0, this.depth = 0, this.tags = 0});

  final int seed;
  final int plies;
  final int depth;
  final int tags;

  /// The game, built afresh each time from the four numbers.
  BuiltGame get game => buildGame(this);

  @override
  String toString() =>
      'GameCase($seed, plies: $plies, depth: $depth, tags: $tags):\n'
      '${game.text}';
}

/// A game as the model holds it and the text the app's writer gives it.
typedef BuiltGame = ({
  List<PgnHeader> tags,
  GameTree tree,
  String? terminator,
  String separator,
  String text,
});

/// Games up to ten plies, with variations nested up to fifty deep a third
/// of the time.
final Generator<GameCase> gameCases = Generator(
  (r) => GameCase(
    r.nextInt(1 << 30),
    plies: r.between(0, 10),
    depth: r.chance(35) ? r.between(1, 50) : 0,
    tags: r.between(0, _optionalTags.length),
  ),
  shrinker: (c) sync* {
    if (c.depth > 0) {
      yield GameCase(c.seed, plies: c.plies, tags: c.tags);
      yield GameCase(c.seed, plies: c.plies, depth: c.depth ~/ 2, tags: c.tags);
    }
    if (c.plies > 0) {
      yield GameCase(c.seed, depth: c.depth, tags: c.tags);
      yield GameCase(c.seed, plies: c.plies - 1, depth: c.depth, tags: c.tags);
    }
    if (c.tags > 0) {
      yield GameCase(c.seed, plies: c.plies, depth: c.depth);
      yield GameCase(c.seed, plies: c.plies, depth: c.depth, tags: c.tags - 1);
    }
  },
);

/// Values a player types into a tag: quotes, backslashes, accents, other
/// scripts, a brace, a semicolon and a percent sign.
const tagValues = [
  'Böhm, Örjan',
  'Nakamura, "Hikaru"',
  r'C:\games\2024',
  'Карпов, Анатолий',
  '王皓',
  'a {brace} and a ; semicolon',
  '100%',
  '',
  ' padded ',
];

/// Tags a game may carry after `[Event]`: the seven-tag roster, the ones
/// this app writes into a chapter, and ones nobody here knows.
const _optionalTags = [
  'Site',
  'Date',
  'White',
  'Black',
  'Round',
  'ChapterName',
  'LineID',
  'CumProb',
  'Annotator',
  'MyEase',
  'X-Unknown_1',
];

const _terminators = [null, '*', '1-0', '0-1', '1/2-1/2'];

/// [c] built: every choice drawn from its seed, the tree through the
/// model's own moves ([growTree], [moveNode]), the tags as this app builds
/// them, and the text from the app's writer.
BuiltGame buildGame(GameCase c) {
  final r = Rand(c.seed);
  final root = r.pick(treeRoots);
  var children = growTree(r, root, c.plies, spellings: r.nextBool());
  if (c.depth > 0) children = _underMainLine(r, root, children, c.depth);
  final tree = GameTree(
    rootFen: root,
    rootComment: r.chance(25) ? treeComment(r) : null,
    children: children,
  );
  final newline = r.chance(25) ? '\r\n' : '\n';
  final tags = <PgnHeader>[
    PgnTag('Event', r.pick(tagValues), trailer: newline),
    for (final key in _optionalTags.take(c.tags))
      PgnTag(key, _valueFor(r, key, c.seed), trailer: newline),
    if (root != treeRoots.first) ...[
      PgnTag('SetUp', '1', trailer: newline),
      PgnTag('FEN', root.value, trailer: newline),
    ],
  ];
  final terminator = r.pick(_terminators);
  if (r.nextBool()) tags.add(PgnTag('Result', terminator ?? '*'));
  final separator = newline;
  return (
    tags: tags,
    tree: tree,
    terminator: terminator,
    separator: separator,
    text: writeGameText(
      tags,
      tree,
      terminator: terminator,
      separator: separator,
    ),
  );
}

String _valueFor(Rand r, String key, int seed) => switch (key) {
  'LineID' => 'line_$seed',
  'ChapterName' => r.pick(const ['Najdorf', 'Dragon: 6.Be3', 'Ünd so']),
  'CumProb' => (r.nextDouble()).toStringAsFixed(4),
  'Date' => r.pick(const ['2024.01.13', '????.??.??']),
  _ => r.pick(tagValues),
};

/// [children] with a chain of variations [depth] deep hung under the last
/// move of its main line, or in place of it when it has no moves.
List<MoveNode> _underMainLine(
  Rand r,
  Fen root,
  List<MoveNode> children,
  int depth,
) {
  if (children.isEmpty) return nestedVariations(r, root, depth);
  final first = children.first;
  return [
    first.copyWith(
      children: _underMainLine(r, first.fen, first.children, depth),
    ),
    ...children.skip(1),
  ];
}

/// Two moves from [fen], the second a variation whose own continuation is
/// two moves again, [depth] times over: a variation inside a variation
/// [depth] deep, each move now and then carrying a comment and a NAG.
List<MoveNode> nestedVariations(Rand r, Fen fen, int depth) {
  if (depth == 0) return const [];
  final position = positionOf(fen);
  if (position == null) return const [];
  final moves = [...legalMovesOf(position)];
  if (moves.length < 2) return const [];
  final main = moveNode(fen, moves.removeAt(r.nextInt(moves.length)))!;
  final side = moveNode(fen, moves[r.nextInt(moves.length)])!;
  MoveNode decorated(MoveNode node, List<MoveNode> children) => node.copyWith(
    comment: r.chance(30) ? treeComment(r) : null,
    startingComment: identical(node, side) && r.chance(20)
        ? treeComment(r)
        : null,
    nags: r.chance(20) ? [treeNag(r)] : const [],
    children: children,
  );
  return [
    decorated(main, const []),
    decorated(side, nestedVariations(r, side.fen, depth - 1)),
  ];
}

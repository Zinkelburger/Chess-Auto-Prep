/// Game trees of real moves for the PGN laws: [growTree] from one of
/// [treeRoots], each move spelled as its SAN or as a spelling files in the
/// wild use and the reader accepts, and [treeDifference] to compare two.
///
/// Search trees for the saved-tree laws: [searchSpecs] and [grownSearch],
/// a real search from one of [searchRoots] against a [SeededEvaluator] and a
/// [SeededPolicy].
library;

import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/generation/eval.dart';
import 'package:chess_auto_prep/chess/generation/legal_moves.dart'
    as generation;
import 'package:chess_auto_prep/chess/generation/search.dart';
import 'package:chess_auto_prep/chess/generation/search_config.dart';
import 'package:chess_auto_prep/chess/generation/search_node.dart';
import 'package:chess_auto_prep/chess/generation/search_result.dart';
import 'package:chess_auto_prep/chess/generation/sources.dart';
import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/chess/pgn/tree_edit.dart';
import 'package:dartchess/dartchess.dart';

import '../props.dart';

/// Where a generated game starts: the initial position, Black to move, a
/// promotion either side, en passant available, castling with one side
/// through an attacked square, mate and stalemate. Written as dartchess
/// writes them, which is the root a game read from them has.
final List<Fen> treeRoots = [
  for (final fen in const [
    'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
    'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
    '4k3/1P6/8/8/8/8/6p1/4K3 w - - 0 1',
    'rnbqkbnr/ppp1p1pp/8/3pPp2/8/8/PPPP1PPP/RNBQKBNR w KQkq f6 0 3',
    'r3k2r/8/8/8/8/8/6b1/R3K2R w KQkq - 0 1',
    'rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3',
    '7k/5Q2/6K1/8/8/8/8/8 b - - 0 1',
  ])
    Fen(positionOf(Fen(fen))!.fen),
];

/// Comment bodies a file may really hold. None holds a `}`, which no PGN
/// comment can.
const treeComments = [
  'A plain note.',
  '[%eval 0.42] [%clk 0:12:03]',
  'Mixed prose [%cal Ge2e4,Rd7d5] and more',
  'braces { inside are text',
  'half a bracket ] and a percent 46.4%',
  '½ → ∞ ♞ and a private glyph ',
  'line one\nline two',
  ' padded ',
  'a; semicolon',
  '',
];

/// A tree of real moves from [fen], [plies] deep, branching where [rand]
/// says so, with comments and annotations on about half the moves.
///
/// Only a move that starts a variation gets a note before it: that is the
/// one place PGN has to write one. See [MoveNode.startingComment]. With
/// [spellings], about one move in five that has another accepted spelling is
/// written that way; see [respelled].
List<MoveNode> growTree(
  Rand rand,
  Fen fen,
  int plies, {
  bool spellings = false,
}) {
  if (plies == 0) return const [];
  final position = positionOf(fen)!;
  final moves = [...legalMovesOf(position)];
  if (moves.isEmpty) return const [];
  final siblings = 1 + (rand.nextInt(4) == 0 ? rand.nextInt(2) + 1 : 0);
  // An en-passant capture, rare among the legal moves, is taken first half
  // the time it is there, so its `e.p.` spelling gets written.
  final picked = <Move>[
    if (spellings && rand.nextBool())
      ...moves.where((m) => _takesEnPassant(position, m)).take(1),
  ];
  moves.removeWhere(picked.contains);
  while (picked.length < siblings && moves.isNotEmpty) {
    picked.add(moves.removeAt(rand.nextInt(moves.length)));
  }
  return [
    for (final (index, move) in picked.indexed)
      _decorated(
        rand,
        _spelled(rand, fen, moveNode(fen, move)!, spellings),
        plies,
        startsVariation: index > 0,
        spellings: spellings,
      ),
  ];
}

MoveNode _spelled(Rand rand, Fen fen, MoveNode node, bool spellings) {
  if (!spellings || !rand.chance(20)) return node;
  final variants = respelled(positionOf(fen)!, node.san);
  if (variants.isEmpty) return node;
  return MoveNode(
    san: node.san,
    uci: node.uci,
    fen: node.fen,
    spelling: rand.pick(variants),
  );
}

MoveNode _decorated(
  Rand rand,
  MoveNode node,
  int plies, {
  required bool startsVariation,
  required bool spellings,
}) => node.copyWith(
  startingComment: startsVariation && rand.nextInt(3) == 0
      ? treeComment(rand)
      : null,
  comment: rand.nextInt(2) == 0 ? treeComment(rand) : null,
  nags: rand.nextInt(4) == 0
      ? [for (var i = 0; i <= rand.nextInt(2); i++) treeNag(rand)]
      : const [],
  children: growTree(rand, node.fen, plies - 1, spellings: spellings),
);

/// A comment from [treeComments] or one carrying machine tokens.
String treeComment(Rand rand) =>
    rand.nextBool() ? rand.pick(treeComments) : comments.sample(rand);

/// A NAG a real file carries, or any of 1–255.
int treeNag(Rand rand) => rand.chance(60)
    ? rand.pick(const [1, 2, 3, 4, 5, 6, 13, 14, 16, 132, 146])
    : rand.between(1, 255);

/// The other spellings of [san] from [position] that the reader takes as
/// the same move: `0-0` castling, a promotion without its `=`, a check
/// without its `+`, and a disambiguation the position does not need.
List<String> respelled(Position position, String san) {
  final check = san.endsWith('+') ? '+' : '';
  final bare = check.isEmpty ? san : san.substring(0, san.length - 1);
  return [
    if (san.startsWith('O-O')) san.replaceAll('O', '0'),
    if (bare.contains('=')) '${bare.replaceAll('=', '')}$check',
    if (check.isNotEmpty) bare,
    ..._overSpecified(position, san),
  ];
}

/// [san] naming the square its piece moves from as well, when it names a
/// piece and none of that.
Iterable<String> _overSpecified(Position position, String san) sync* {
  final shape = RegExp(r'^([NBRQK])(x?[a-h][1-8][+#]?)$').firstMatch(san);
  if (shape == null) return;
  final move = position.parseSan(san);
  if (move is! NormalMove) return;
  final from = move.from.name;
  yield '${shape[1]}${from[0]}${shape[2]}';
  yield '${shape[1]}$from${shape[2]}';
}

bool _takesEnPassant(Position position, Move move) =>
    move is NormalMove &&
    move.to == position.epSquare &&
    position.board.roleAt(move.from) == Role.pawn;

/// Whether [node] is an en-passant capture from [before], which a file may
/// follow with `e.p.`.
bool isEnPassant(Fen before, MoveNode node) {
  final position = positionOf(before);
  final move = position?.parseSan(node.san);
  return move != null && _takesEnPassant(position!, move);
}

/// The first way [actual] differs from [expected] — every field of every
/// node, the order of variations included — or null when it does not.
String? treeDifference(GameTree actual, GameTree expected) {
  if (actual.rootFen != expected.rootFen) {
    return 'root ${actual.rootFen} is not ${expected.rootFen}';
  }
  if (actual.rootComment != expected.rootComment) {
    return 'root comment ${_q(actual.rootComment)} '
        'is not ${_q(expected.rootComment)}';
  }
  return _childrenDifference(actual.children, expected.children, '');
}

String? _childrenDifference(
  List<MoveNode> actual,
  List<MoveNode> expected,
  String path,
) {
  if (actual.length != expected.length) {
    return 'at [$path] ${actual.map((n) => n.san).toList()} '
        'is not ${expected.map((n) => n.san).toList()}';
  }
  for (var i = 0; i < actual.length; i++) {
    final here = path.isEmpty ? '$i' : '$path/$i';
    final difference =
        _nodeDifference(actual[i], expected[i], here) ??
        _childrenDifference(actual[i].children, expected[i].children, here);
    if (difference != null) return difference;
  }
  return null;
}

String? _nodeDifference(MoveNode a, MoveNode e, String path) {
  final fields = {
    'san': (a.san, e.san),
    'uci': (a.uci, e.uci),
    'fen': (a.fen.value, e.fen.value),
    'spelling': (a.spelling, e.spelling),
    'startingComment': (a.startingComment, e.startingComment),
    'comment': (a.comment, e.comment),
    'nags': (a.nags.join(','), e.nags.join(',')),
  };
  for (final MapEntry(key: name, value: (got, want)) in fields.entries) {
    if (got == want) continue;
    return 'at [$path] ${e.san} $name ${_q(got)} is not ${_q(want)}';
  }
  return null;
}

String _q(Object? value) => value == null ? 'null' : '"$value"';

/// Every node of [tree] with the position it was played from.
Iterable<(Fen, MoveNode)> nodesWithParents(GameTree tree) sync* {
  final pending = [for (final child in tree.children) (tree.rootFen, child)];
  while (pending.isNotEmpty) {
    final (parent, node) = pending.removeLast();
    yield (parent, node);
    pending.addAll([for (final child in node.children) (node.fen, child)]);
  }
}

/// Why [node] is not its move played from [parent], or null when it is: the
/// same SAN, the same position after it.
String? illegalStep(Fen parent, MoveNode node) {
  final position = positionOf(parent);
  if (position == null) return 'no position before ${node.san}';
  if (node.uci == '0000') {
    final (_, after) = nullMovePlayed(position, spelling: node.san);
    return after.fen == node.fen.value ? null : 'null move to ${node.fen}';
  }
  final move = Move.parse(node.uci);
  if (move == null || !position.isLegal(move)) {
    return '${node.san} (${node.uci}) is not legal from $parent';
  }
  final (after, san) = position.makeSan(move);
  if (san != node.san) return '${node.uci} is $san, not ${node.san}';
  if (after.fen != node.fen.value) return '${node.san} reaches ${after.fen}';
  return null;
}

// ---------------------------------------------------------------------------
// Search trees
// ---------------------------------------------------------------------------

/// Where a generated search starts: few enough moves that three plies stay
/// small, and between them every kind of leaf — a pawn to promote, castling
/// both ways, a mate, a stalemate, the fifty-move rule and a capture that
/// leaves too little to mate with. Either side to move.
const searchRoots = [
  '4k3/8/8/8/8/8/4P3/4K3 w - - 0 1',
  '4k3/8/8/8/8/8/4P3/4K3 b - - 0 1',
  '4k3/8/8/8/8/8/4P3/4K3 w - - 99 60',
  'k7/8/1K6/8/8/8/7Q/8 w - - 0 1',
  'k7/8/8/2Q5/8/8/8/7K w - - 0 1',
  'k7/8/8/8/8/8/1p6/K7 w - - 0 1',
  '8/4P3/8/8/8/8/k7/4K3 w - - 0 1',
  'r3k3/8/8/8/8/8/8/4K2R w Kq - 0 1',
];

/// A number fixed by [text] and [seed] alone, the same on every machine:
/// FNV-1a over the code units. `String.hashCode` is not promised to be.
int stableHash(String text, int seed) {
  var hash = (0x811c9dc5 ^ seed) & 0xFFFFFFFF;
  for (final unit in text.codeUnits) {
    hash = ((hash ^ unit) * 0x01000193) & 0xFFFFFFFF;
  }
  return hash;
}

/// An engine whose score for a position is fixed by the position and
/// [seed]: anything within three pawns, and now and then a mate either way.
final class SeededEvaluator implements PositionEvaluator {
  const SeededEvaluator(this.seed);

  final int seed;

  @override
  Future<EvaluationResult> evaluate(Position position) async {
    final hash = stableHash(position.fen, seed);
    final cp = hash % 13 == 0
        ? (hash.isEven ? 1 : -1) * (mateBaseCp - 1 - hash % 20)
        : hash % 601 - 300;
    return Evaluated(Eval(cp));
  }
}

/// An opponent model whose weights at a position are fixed by the position
/// and [seed]: most legal moves get some, a few none, and at [missing]
/// percent of positions it has no answer at all.
final class SeededPolicy implements OpponentPolicy {
  const SeededPolicy(this.seed, {this.missing = 0});

  final int seed;
  final int missing;

  @override
  Future<PolicyResult> policyFor(Position position) async {
    if (stableHash(position.fen, seed ^ 0x5eed) % 100 < missing) {
      return const PolicyUnavailable('the seeded model skips this position');
    }
    final weights = <String, double>{};
    for (final (:uci, move: _) in generation.legalMovesOf(position)) {
      final hash = stableHash('${position.fen} $uci', seed);
      weights[uci] = hash % 5 == 0 ? 0 : (hash % 1000 + 1) / 997;
    }
    // A model always has some move it expects.
    if (weights.values.every((w) => w == 0) && weights.isNotEmpty) {
      weights[weights.keys.first] = 1;
    }
    return PolicyFound(Policy(weights));
  }
}

/// One search to run: from which root, with which settings, against which
/// seeded sources, and whether it is stopped or starved of answers part way.
final class SearchSpec {
  const SearchSpec({
    required this.seed,
    required this.root,
    required this.config,
    this.cancelAfter,
    this.missingPolicy = 0,
  });

  final int seed;
  final String root;
  final SearchConfig config;

  /// The search is asked to stop after this many checks, or never.
  final int? cancelAfter;

  /// Percent of positions the opponent model has nothing to say about.
  final int missingPolicy;

  @override
  String toString() =>
      'SearchSpec(seed: $seed, root: $root, side: ${config.side.name}, '
      'horizon: ${config.horizonPlies}, loss: ${config.lossLimitCp}, '
      'budget: ${config.nodeBudget}, ours: ${config.maxOurMoves}, '
      'rootMoves: ${config.rootMoves}, floor: ${config.replyFloor}, '
      'cancelAfter: $cancelAfter, missingPolicy: $missingPolicy)';
}

/// Searches with a horizon of three plies or less, or none at all under a
/// small node budget; every loss window, shortlist and reply floor the
/// Builder offers; now and then stopped early or short of a policy.
final Generator<SearchSpec> searchSpecs = Generator(
  (rand) {
    final horizon = rand.chance(10) ? null : rand.between(1, 3);
    final shortlist = rand.chance(40) ? rand.between(1, 4) : null;
    return SearchSpec(
      seed: rand.between(0, 1 << 30),
      root: rand.pick(searchRoots),
      config: SearchConfig(
        side: rand.nextBool() ? Side.white : Side.black,
        horizonPlies: horizon,
        lossLimitCp: rand.pick(const [null, 0, 50, 200]),
        nodeBudget: horizon == null || rand.chance(60)
            ? rand.between(2, 300)
            : null,
        maxOurMoves: shortlist,
        rootMoves: shortlist != null && rand.nextBool()
            ? rand.between(1, 3)
            : null,
        replyFloor: rand.pick(const [0.0, 0.0, 0.05, 0.3]),
      ),
      cancelAfter: rand.chance(15) ? rand.between(0, 40) : null,
      missingPolicy: rand.chance(10) ? 20 : 0,
    );
  },
  shrinker: (spec) sync* {
    final horizon = spec.config.horizonPlies;
    if (horizon != null && horizon > 1) {
      yield SearchSpec(
        seed: spec.seed,
        root: spec.root,
        config: _withHorizon(spec.config, horizon - 1),
        cancelAfter: spec.cancelAfter,
        missingPolicy: spec.missingPolicy,
      );
    }
    if (spec.root != searchRoots.first) {
      yield SearchSpec(
        seed: spec.seed,
        root: searchRoots.first,
        config: spec.config,
        cancelAfter: spec.cancelAfter,
        missingPolicy: spec.missingPolicy,
      );
    }
  },
);

SearchConfig _withHorizon(SearchConfig c, int horizon) => SearchConfig(
  side: c.side,
  horizonPlies: horizon,
  lossLimitCp: c.lossLimitCp,
  nodeBudget: c.nodeBudget,
  maxOurMoves: c.maxOurMoves,
  rootMoves: c.rootMoves,
  replyFloor: c.replyFloor,
);

/// The tree [spec]'s search built, and whether it reached the horizon
/// everywhere; null when it stopped before the root had a value. A search
/// that stopped for want of an answer keeps what it had built, as a Builder
/// saves it.
Future<({SearchNode tree, bool complete})?> grownSearch(SearchSpec spec) async {
  var checks = 0;
  final result = await buildSearchTree(
    root: Chess.fromSetup(Setup.parseFen(spec.root)),
    config: spec.config,
    evaluator: SeededEvaluator(spec.seed),
    policy: SeededPolicy(spec.seed, missing: spec.missingPolicy),
    isCancelled: () =>
        spec.cancelAfter != null && checks++ >= spec.cancelAfter!,
  );
  return switch (result) {
    SearchComplete(:final tree) => (tree: tree, complete: true),
    SearchIncomplete(:final tree) => (tree: tree, complete: false),
    PolicyMissing(:final tree?) => (tree: tree, complete: false),
    EvaluationFailed(:final tree?) => (tree: tree, complete: false),
    PolicyMissing() || EvaluationFailed() => null,
  };
}

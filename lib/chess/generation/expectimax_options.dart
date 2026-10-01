import 'evaluation_source.dart';

/// What a search builds: expectimax against the human model, or ChessDB's
/// objectively best book (`mainline_book.dart`).
enum SearchMethod {
  practical('Maia practical'),
  mainline('ChessDB mainline');

  const SearchMethod(this.label);
  final String label;
}

/// Where the search learns which replies the opponent plays and how often:
/// the Maia model, or the games of a database.
enum ReplySource {
  maia('Maia'),

  /// Lichess's masters database: titled players, over the board. Online.
  masters('Lichess masters'),

  /// Lichess's own games, at the speeds and ratings the Explorer tab asks
  /// for. Online.
  lichess('Lichess players'),

  /// The master games on this machine.
  twic('TWIC games');

  const ReplySource(this.label);
  final String label;
}

/// How the next search from the board is set: chosen on the Expectimax
/// tab or in Settings, and kept between launches.
final class ExpectimaxOptions {
  const ExpectimaxOptions({
    this.method = SearchMethod.practical,
    this.depth,
    this.rootMoves = 4,
    this.candidateMoves = 4,
    this.rareOnceIn = 100,
    this.evalDepth = defaultEvalDepth,
    this.source = EvaluationSource.stockfish,
    this.replies = ReplySource.maia,
    this.maiaFallback = true,
    this.fallbackUnder = 10,
  });

  final SearchMethod method;

  /// How many half-moves past the board the search looks; null goes on
  /// until it is paused.
  final int? depth;

  /// Our moves kept for the first move of the search.
  final int rootMoves;

  /// Our moves kept at every later move of ours.
  final int candidateMoves;

  /// A reply path met less than once in this many games keeps its engine
  /// value and is not searched further. Zero searches every reply.
  final int rareOnceIn;

  /// The engine depth each position is scored at.
  final int evalDepth;
  final EvaluationSource source;

  /// Where the opponent's replies come from.
  final ReplySource replies;

  /// Whether a position the database has fewer than [fallbackUnder] games
  /// at is answered by Maia instead. Without it the database answers
  /// wherever it has a game, and the search stops where it has none.
  final bool maiaFallback;
  final int fallbackUnder;

  static const defaults = ExpectimaxOptions();

  /// The range a search's depth may be set to, when it is set at all.
  static const minDepth = 1;
  static const maxDepth = 64;

  /// No position has more legal moves than this.
  static const maxMoves = 218;

  /// The engine depth unless another is asked for, and the range it may be
  /// set to; the shared cache is keyed on the depth.
  static const defaultEvalDepth = 14;
  static const minEvalDepth = 1;
  static const maxEvalDepth = 40;

  /// One game in two is not rare; past this nothing is.
  static const maxRareOnceIn = 100000;

  /// The most games a database may be asked for before it is believed.
  static const maxFallbackUnder = 100000;

  /// The share of games under which a reply path is left unsearched.
  double get replyFloor => rareOnceIn == 0 ? 0 : 1 / rareOnceIn;

  ExpectimaxOptions copyWith({
    SearchMethod? method,
    int? rootMoves,
    int? candidateMoves,
    int? rareOnceIn,
    int? evalDepth,
    EvaluationSource? source,
    ReplySource? replies,
    bool? maiaFallback,
    int? fallbackUnder,
  }) => ExpectimaxOptions(
    method: method ?? this.method,
    depth: depth,
    rootMoves: rootMoves ?? this.rootMoves,
    candidateMoves: candidateMoves ?? this.candidateMoves,
    rareOnceIn: rareOnceIn ?? this.rareOnceIn,
    evalDepth: evalDepth ?? this.evalDepth,
    source: source ?? this.source,
    replies: replies ?? this.replies,
    maiaFallback: maiaFallback ?? this.maiaFallback,
    fallbackUnder: fallbackUnder ?? this.fallbackUnder,
  );

  /// These options with [depth], which may be none.
  ExpectimaxOptions withDepth(int? depth) => ExpectimaxOptions(
    method: method,
    depth: depth,
    rootMoves: rootMoves,
    candidateMoves: candidateMoves,
    rareOnceIn: rareOnceIn,
    evalDepth: evalDepth,
    source: source,
    replies: replies,
    maiaFallback: maiaFallback,
    fallbackUnder: fallbackUnder,
  );

  Map<String, Object?> toJson() => {
    'method': method.name,
    'depth': depth,
    'rootMoves': rootMoves,
    'candidateMoves': candidateMoves,
    'rareOnceIn': rareOnceIn,
    'evalDepth': evalDepth,
    'source': source.name,
    'replies': replies.name,
    'maiaFallback': maiaFallback,
    'fallbackUnder': fallbackUnder,
  };

  /// Reads [value]; a field that is missing, of the wrong type or out of
  /// range keeps its default.
  factory ExpectimaxOptions.fromJson(Object? value) {
    if (value is! Map<String, Object?>) return defaults;
    int number(String key, int fallback, int min, int max) {
      final n = value[key];
      return n is int && n >= min && n <= max ? n : fallback;
    }

    final depth = value['depth'];
    final rare = number('rareOnceIn', defaults.rareOnceIn, 0, maxRareOnceIn);
    return ExpectimaxOptions(
      method:
          SearchMethod.values.asNameMap()[value['method']] ?? defaults.method,
      depth: depth is int && depth >= minDepth && depth <= maxDepth
          ? depth
          : null,
      rootMoves: number('rootMoves', defaults.rootMoves, 1, maxMoves),
      candidateMoves: number(
        'candidateMoves',
        defaults.candidateMoves,
        1,
        maxMoves,
      ),
      rareOnceIn: rare == 1 ? defaults.rareOnceIn : rare,
      evalDepth: number(
        'evalDepth',
        defaults.evalDepth,
        minEvalDepth,
        maxEvalDepth,
      ),
      source:
          EvaluationSource.values.asNameMap()[value['source']] ??
          defaults.source,
      replies:
          ReplySource.values.asNameMap()[value['replies']] ?? defaults.replies,
      maiaFallback: value['maiaFallback'] is bool
          ? value['maiaFallback'] as bool
          : defaults.maiaFallback,
      fallbackUnder: number(
        'fallbackUnder',
        defaults.fallbackUnder,
        1,
        maxFallbackUnder,
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ExpectimaxOptions &&
      method == other.method &&
      depth == other.depth &&
      rootMoves == other.rootMoves &&
      candidateMoves == other.candidateMoves &&
      rareOnceIn == other.rareOnceIn &&
      evalDepth == other.evalDepth &&
      source == other.source &&
      replies == other.replies &&
      maiaFallback == other.maiaFallback &&
      fallbackUnder == other.fallbackUnder;

  @override
  int get hashCode => Object.hash(
    method,
    depth,
    rootMoves,
    candidateMoves,
    rareOnceIn,
    evalDepth,
    source,
    replies,
    maiaFallback,
    fallbackUnder,
  );
}

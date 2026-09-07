/// A small, seeded property-testing kit: `forAll` plus the generators the PGN
/// layer needs.
///
/// Property tests assert *laws* (`parse(serialize(x)) == x`) instead of
/// pinning today's output, so they keep their meaning across a refactor. The
/// price is that a failure arrives as a random value, which is why this kit
/// is deterministic (same seed ⇒ same values, on every machine — the PRNG is
/// ours, not `dart:math`'s) and shrinks a failure toward a minimal
/// counterexample before reporting it, with the seed attached.
///
/// No new dependencies: `dartchess` (already a dependency) plays the random
/// legal moves, `flutter_test` declares the test.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Deterministic PRNG
// ---------------------------------------------------------------------------

/// xorshift32. `dart:math`'s `Random(seed)` is only documented to be stable
/// within one VM implementation; a reported seed has to reproduce anywhere.
class Rand {
  Rand(int seed) : _s = _scramble(seed);

  int _s;

  static int _scramble(int seed) {
    var x = (seed ^ 0x9E3779B9) & 0xFFFFFFFF;
    if (x == 0) x = 0x1BADB002;
    for (var i = 0; i < 5; i++) {
      x ^= (x << 13) & 0xFFFFFFFF;
      x ^= x >> 17;
      x ^= (x << 5) & 0xFFFFFFFF;
      x &= 0xFFFFFFFF;
    }
    return x == 0 ? 1 : x;
  }

  int _next() {
    var x = _s;
    x ^= (x << 13) & 0xFFFFFFFF;
    x ^= x >> 17;
    x ^= (x << 5) & 0xFFFFFFFF;
    _s = x & 0xFFFFFFFF;
    return _s;
  }

  int nextInt(int max) => max <= 0 ? 0 : _next() % max;

  /// Inclusive on both ends.
  int between(int lo, int hi) => hi <= lo ? lo : lo + nextInt(hi - lo + 1);

  bool nextBool() => _next().isOdd;

  /// True [percent] of the time.
  bool chance(int percent) => nextInt(100) < percent;

  double nextDouble() => _next() / 4294967296.0;

  T pick<T>(List<T> values) => values[nextInt(values.length)];
}

// ---------------------------------------------------------------------------
// Generators
// ---------------------------------------------------------------------------

typedef Shrink<T> = Iterable<T> Function(T value);

/// A value source plus, optionally, the ways to make one of its values
/// smaller. [shrink] returns candidates in "most aggressive first" order; the
/// runner keeps whichever still fails.
class Generator<T> {
  const Generator(this.sample, {this.shrinker});

  final T Function(Rand rand) sample;
  final Shrink<T>? shrinker;

  Iterable<T> shrink(T value) => shrinker?.call(value) ?? const [];

  /// Derived generator. Shrinking does not survive a map — map late, or give
  /// the derived generator its own shrinker.
  Generator<R> map<R>(R Function(T value) f) =>
      Generator((rand) => f(sample(rand)));
}

Generator<int> ints(int min, int max) => Generator(
  (r) => r.between(min, max),
  shrinker: (v) sync* {
    if (v == min) return;
    yield min;
    if (v > min + 1) yield min + (v - min) ~/ 2;
    yield v - 1;
  },
);

const Generator<bool> bools = Generator(_sampleBool);
bool _sampleBool(Rand r) => r.nextBool();

Generator<T> choice<T>(List<T> values) => Generator(
  (r) => r.pick(values),
  shrinker: (v) sync* {
    final i = values.indexOf(v);
    if (i > 0) yield values.first;
  },
);

Generator<List<T>> listOf<T>(Generator<T> item, {int min = 0, int max = 6}) =>
    Generator(
      (r) => [for (var i = r.between(min, max); i > 0; i--) item.sample(r)],
      shrinker: (v) sync* {
        if (v.length > min) {
          if (v.length > min + 1) yield v.take(min).toList();
          yield v.take(v.length - 1).toList();
          if (v.length > 1) yield v.skip(1).toList();
        }
      },
    );

// ---------------------------------------------------------------------------
// The runner
// ---------------------------------------------------------------------------

/// Declare a test that runs [body] over [runs] generated values.
///
/// On the first failure the input is shrunk toward a minimal counterexample
/// and both the seed and the shrunk value are reported, so the failure can be
/// replayed with `forAll(..., seed: <printed>)`.
void forAll<T>(
  String description,
  Generator<T> gen,
  void Function(T value) body, {
  int runs = 200,
  int seed = 0x0C4E55,
}) {
  test(description, () {
    for (var i = 0; i < runs; i++) {
      final caseSeed = seed + i;
      final value = gen.sample(Rand(caseSeed));
      final failure = _run(body, value);
      if (failure == null) continue;
      final minimal = _minimize(gen, value, body);
      final minimalFailure = _run(body, minimal) ?? failure;
      fail(
        'Property failed: $description\n'
        '  seed:       $seed (case $i, caseSeed $caseSeed)\n'
        '  replay:     forAll(..., seed: $caseSeed, runs: 1)\n'
        '  generated:  ${_show(value)}\n'
        '  shrunk to:  ${_show(minimal)}\n'
        '  failure:    $minimalFailure',
      );
    }
  });
}

Object? _run<T>(void Function(T) body, T value) {
  try {
    body(value);
    return null;
  } catch (e) {
    return e;
  }
}

T _minimize<T>(Generator<T> gen, T failing, void Function(T) body) {
  var best = failing;
  var budget = 400;
  var improved = true;
  while (improved && budget > 0) {
    improved = false;
    for (final candidate in gen.shrink(best)) {
      if (--budget <= 0) break;
      if (_run(body, candidate) != null) {
        best = candidate;
        improved = true;
        break;
      }
    }
  }
  return best;
}

String _show(Object? value) {
  final text = value.toString();
  return text.length > 900 ? '${text.substring(0, 900)}…' : text;
}

// ---------------------------------------------------------------------------
// Chess-shaped generators
// ---------------------------------------------------------------------------

/// Every legal move of [pos], promotions expanded to all four pieces.
List<Move> legalMovesOf(Position pos) {
  final moves = <Move>[];
  for (final entry in pos.legalMoves.entries) {
    final from = entry.key;
    final isPawn = pos.board.roleAt(from) == Role.pawn;
    for (final to in entry.value.squares) {
      if (isPawn && (to >= 56 || to < 8)) {
        for (final role in const [
          Role.queen,
          Role.rook,
          Role.bishop,
          Role.knight,
        ]) {
          moves.add(NormalMove(from: from, to: to, promotion: role));
        }
      } else {
        moves.add(NormalMove(from: from, to: to));
      }
    }
  }
  return moves;
}

/// [plies] random legal moves from [start], as SAN. Stops early at mate or a
/// dead position.
List<String> playRandomLine(Rand rand, Position start, int plies) {
  final sans = <String>[];
  var pos = start;
  for (var i = 0; i < plies; i++) {
    if (pos.isGameOver) break;
    final moves = legalMovesOf(pos);
    if (moves.isEmpty) break;
    final (next, san) = pos.makeSan(rand.pick(moves));
    sans.add(san);
    pos = next;
  }
  return sans;
}

/// A random legal game from the initial position: real SAN, including the
/// castling, promotion, disambiguation and check shapes a serializer trips on.
Generator<List<String>> randomLines({int minPlies = 1, int maxPlies = 24}) =>
    Generator(
      (r) => playRandomLine(r, Chess.initial, r.between(minPlies, maxPlies)),
      shrinker: (v) sync* {
        if (v.length > minPlies) {
          if (v.length > minPlies + 1) yield v.take(minPlies).toList();
          yield v.take(v.length - 1).toList();
        }
      },
    );

/// A single random legal SAN, drawn from a real game rather than a fixture
/// list, so `exd8=Q+`, `Nbd7`, `R1a3` and `O-O-O` all turn up.
final Generator<String> sans = Generator((r) {
  final line = playRandomLine(r, Chess.initial, r.between(1, 30));
  return line.isEmpty ? 'e4' : line.last;
});

/// The `$n` sets a real PGN carries: a quality verdict (1–6), a positional
/// assessment, or both — plus the unknown ids an import can bring in.
final Generator<List<int>> nagSets = Generator(
  (r) => [
    if (r.chance(60)) r.between(1, 6),
    if (r.chance(35))
      r.pick(const [7, 13, 14, 15, 16, 17, 18, 19, 36, 40, 146]),
    if (r.chance(10)) r.between(200, 255),
  ],
  shrinker: (v) sync* {
    if (v.isNotEmpty) {
      yield const <int>[];
      yield v.take(v.length - 1).toList();
    }
  },
);

/// The `[%tag …]` tokens the app writes and reads back.
String randomToken(Rand rand) {
  switch (rand.nextInt(9)) {
    case 0:
      final cp = rand.between(-2000, 2000) / 100.0;
      final depth = rand.chance(50) ? ',${rand.between(1, 60)}' : '';
      return '[%eval ${cp.toStringAsFixed(2)}$depth]';
    case 1:
      final mate = rand.between(-20, 20);
      return '[%eval #$mate${rand.chance(50) ? ',${rand.between(1, 60)}' : ''}]';
    case 2:
      return '[%clk 0:${rand.between(0, 59).toString().padLeft(2, '0')}:'
          '${rand.between(0, 59).toString().padLeft(2, '0')}]';
    case 3:
      final line = playRandomLine(rand, Chess.initial, rand.between(1, 6));
      return line.isEmpty ? '[%pv e4]' : '[%pv ${line.join(',')}]';
    case 4:
      return '[%cal Gd4e5,Rf1c4]';
    case 5:
      return '[%csl Ye4,Gd5]';
    case 6:
      return '[%maiaProbability ${rand.nextDouble().toStringAsFixed(3)}]';
    case 7:
      return '[%cumProb ${(rand.nextDouble() * 100).toStringAsFixed(3)}%]';
    default:
      return '[%emt 0:00:${rand.between(0, 59).toString().padLeft(2, '0')}]';
  }
}

/// Human prose of the kind book and study PGNs carry — brackets, parens,
/// semicolons, percent signs, double spaces, unicode symbols.
///
/// Deliberately free of `{` and `}`: PGN has no escape for either inside a
/// comment (dartchess's own writer deletes `}`), so a comment containing one
/// is not representable and says nothing about the round-trip laws.
const List<String> proseFragments = [
  'Best by test',
  'White is slightly better ⩲',
  'see (a) and [b] below',
  'the plan: c4-c5, then Nd5',
  'a  double  space  paragraph',
  '100% winning',
  'Black holds; the ending is drawn',
  'Kasparov–Karpov, Linares 1993',
  'Не лучший ход',
  '!? — a practical try',
];

/// A comment as a real PGN carries it: machine tokens, prose, or both, in
/// either order, with the spacing real exports use.
final Generator<String> comments = Generator(
  (r) {
    final tokens = [for (var i = r.between(0, 3); i > 0; i--) randomToken(r)];
    final prose = [
      for (var i = r.between(0, 2); i > 0; i--) r.pick(proseFragments),
    ];
    final parts = r.nextBool() ? [...tokens, ...prose] : [...prose, ...tokens];
    final joined = parts.join(r.chance(20) ? '' : ' ');
    if (joined.isEmpty) return '';
    if (r.chance(20)) return ' $joined ';
    return joined;
  },
  shrinker: (v) sync* {
    if (v.isEmpty) return;
    yield '';
    final parts = v.trim().split(' ');
    if (parts.length > 1) {
      yield parts.take(parts.length - 1).join(' ');
      yield parts.skip(1).join(' ');
    }
    if (v != v.trim()) yield v.trim();
  },
);

// ---------------------------------------------------------------------------
// Whole annotated games, as a spec that renders to PGN text
// ---------------------------------------------------------------------------

/// One ply of a generated game, with everything a PGN can hang on a move.
class PlySpec {
  const PlySpec({
    required this.san,
    this.nags = const [],
    this.comment,
    this.startingComment,
    this.variation = const [],
    this.glyph = '',
  });

  final String san;
  final List<int> nags;

  /// `{…}` written *after* the move (dartchess: `comments`).
  final String? comment;

  /// `{…}` written *before* the move (dartchess: `startingComments`).
  final String? startingComment;

  /// A legal alternative line from the position before this ply, rendered as
  /// `( … )`.
  final List<String> variation;

  /// A trailing `!`/`?!`/… glyph, which is not a move and not a NAG.
  final String glyph;

  PlySpec copyWith({
    List<int>? nags,
    Object? comment = _keep,
    Object? startingComment = _keep,
    List<String>? variation,
    String? glyph,
  }) => PlySpec(
    san: san,
    nags: nags ?? this.nags,
    comment: comment == _keep ? this.comment : comment as String?,
    startingComment: startingComment == _keep
        ? this.startingComment
        : startingComment as String?,
    variation: variation ?? this.variation,
    glyph: glyph ?? this.glyph,
  );

  static const _keep = Object();

  @override
  String toString() =>
      'PlySpec($san'
      '${nags.isEmpty ? '' : ' nags=$nags'}'
      '${comment == null ? '' : ' {$comment}'}'
      '${startingComment == null ? '' : ' pre{$startingComment}'}'
      '${variation.isEmpty ? '' : ' (${variation.join(' ')})'}'
      '${glyph.isEmpty ? '' : ' $glyph'})';
}

/// A generated game, and the PGN text it renders to.
class GameSpec {
  const GameSpec({
    required this.plies,
    required this.headers,
    required this.result,
    this.crlf = false,
    this.escapeLine = false,
    this.lineComment = false,
  });

  final List<PlySpec> plies;
  final Map<String, String> headers;
  final String result;

  /// Render with `\r\n`, as a Windows-authored file does.
  final bool crlf;

  /// Put a `%`-escape line in the middle of the movetext.
  final bool escapeLine;

  /// Put a `;` rest-of-line comment in the middle of the movetext.
  final bool lineComment;

  List<String> get sans => [for (final p in plies) p.san];

  /// PGN text: a header block, a blank line, then movetext broken across
  /// lines the way a real file is. Every move carries its full number, which
  /// is legal PGN and keeps the renderer honest — both parsers under test
  /// ignore move numbers and read the moves.
  String render() {
    final buf = StringBuffer();
    headers.forEach((k, v) {
      final escaped = v.replaceAll('\\', r'\\').replaceAll('"', r'\"');
      buf.write('[$k "$escaped"]\n');
    });
    buf.write('\n');

    var col = 0;
    void tok(String s) {
      buf.write(s);
      buf.write(' ');
      col += s.length + 1;
      if (col > 60) {
        buf.write('\n');
        col = 0;
      }
    }

    for (var i = 0; i < plies.length; i++) {
      final ply = plies[i];
      final number = i ~/ 2 + 1;
      if (ply.startingComment != null) tok('{${ply.startingComment}}');
      tok('$number${i.isEven ? '.' : '...'}');
      tok('${ply.san}${ply.glyph}');
      for (final nag in ply.nags) {
        tok('\$$nag');
      }
      if (ply.comment != null) tok('{${ply.comment}}');
      if (ply.variation.isNotEmpty) {
        final v = StringBuffer('(');
        for (var j = 0; j < ply.variation.length; j++) {
          final n = (i + j) ~/ 2 + 1;
          v.write(' $n${(i + j).isEven ? '.' : '...'} ${ply.variation[j]}');
        }
        v.write(' )');
        tok(v.toString());
      }
      if (i == plies.length ~/ 2) {
        if (lineComment) {
          buf.write('; a rest-of-line comment 9. Qxf7#\n');
          col = 0;
        }
        if (escapeLine) {
          if (col != 0) buf.write('\n');
          buf.write('% an escaped line 9. Qxf7#\n');
          col = 0;
        }
      }
    }
    buf.write(result);
    buf.write('\n');
    final text = buf.toString();
    return crlf ? text.replaceAll('\n', '\r\n') : text;
  }

  GameSpec copyWith({List<PlySpec>? plies, bool? escapeLine, bool? crlf}) =>
      GameSpec(
        plies: plies ?? this.plies,
        headers: headers,
        result: result,
        crlf: crlf ?? this.crlf,
        escapeLine: escapeLine ?? this.escapeLine,
        lineComment: lineComment,
      );

  @override
  String toString() => 'GameSpec(${render()})';
}

/// Whole games with real SAN, real annotations and real PGN furniture.
///
/// [withVariations], [withStartingComments] and [withFurniture] (`%` escape
/// lines, `;` comments, CRLF) are off for laws that do not survive them —
/// `buildMovetext`, for instance, is documented to serialize a flat mainline.
Generator<GameSpec> annotatedGames({
  int minPlies = 1,
  int maxPlies = 16,
  bool withVariations = true,
  bool withStartingComments = true,
  bool withFurniture = true,
}) => Generator(
  (r) {
    final plies = <PlySpec>[];
    Position pos = Chess.initial;
    final target = r.between(minPlies, maxPlies);
    for (var i = 0; i < target; i++) {
      if (pos.isGameOver) break;
      final moves = legalMovesOf(pos);
      if (moves.isEmpty) break;
      final variation = withVariations && r.chance(25)
          ? playRandomLine(r, pos, r.between(1, 3))
          : const <String>[];
      final (next, san) = pos.makeSan(r.pick(moves));
      plies.add(
        PlySpec(
          san: san,
          nags: r.chance(35) ? nagSets.sample(r) : const [],
          comment: r.chance(45) ? comments.sample(r) : null,
          startingComment: withStartingComments && r.chance(12)
              ? comments.sample(r)
              : null,
          variation: variation,
          glyph: r.chance(10) ? r.pick(const ['!', '?', '!?', '??']) : '',
        ),
      );
      pos = next;
    }
    return GameSpec(
      plies: plies,
      headers: {
        'Event': r.pick(const ['Test', 'the "real" one', r'c:\games']),
        'White': 'A. Player',
        'Black': 'B. Player',
        'Result': '*',
      },
      result: r.pick(const ['*', '1-0', '0-1', '1/2-1/2']),
      crlf: withFurniture && r.chance(15),
      escapeLine: withFurniture && r.chance(15),
      lineComment: withFurniture && r.chance(15),
    );
  },
  shrinker: (g) sync* {
    if (g.plies.length > 1) {
      yield g.copyWith(plies: g.plies.take(1).toList());
      yield g.copyWith(plies: g.plies.take(g.plies.length - 1).toList());
      yield g.copyWith(plies: g.plies.skip(1).toList());
    }
    if (g.crlf) yield g.copyWith(crlf: false);
    if (g.escapeLine) yield g.copyWith(escapeLine: false);
    for (var i = 0; i < g.plies.length; i++) {
      final p = g.plies[i];
      if (p.variation.isNotEmpty) {
        yield g.copyWith(
          plies: _replace(g.plies, i, p.copyWith(variation: [])),
        );
      }
      if (p.startingComment != null) {
        yield g.copyWith(
          plies: _replace(g.plies, i, p.copyWith(startingComment: null)),
        );
      }
      if (p.comment != null) {
        yield g.copyWith(
          plies: _replace(g.plies, i, p.copyWith(comment: null)),
        );
      }
      if (p.nags.isNotEmpty) {
        yield g.copyWith(plies: _replace(g.plies, i, p.copyWith(nags: [])));
      }
      if (p.glyph.isNotEmpty) {
        yield g.copyWith(plies: _replace(g.plies, i, p.copyWith(glyph: '')));
      }
    }
  },
);

List<PlySpec> _replace(List<PlySpec> plies, int index, PlySpec value) => [
  for (var i = 0; i < plies.length; i++) i == index ? value : plies[i],
];

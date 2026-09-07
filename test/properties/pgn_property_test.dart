/// Laws the PGN layer must obey, checked over generated real-shaped input.
///
/// These are *property* tests: each one states something that has to stay
/// true of any input (`parse(serialize(x))` reads back as `x`; an edit changes
/// only the prose; a NAG never vanishes), so it keeps its meaning when the
/// implementation is rewritten. None of them pins today's output text.
///
/// The generators live in `test/support/props.dart`: real legal games from
/// `package:dartchess`, real `[%tag …]` payloads, real NAG sets. A failure
/// reports the seed and a shrunk counterexample.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/services/generation/export/move_annotation.dart';
import 'package:chess_auto_prep/services/pgn_parsing_service.dart';
import 'package:chess_auto_prep/utils/chess_utils.dart' show isNullMoveSan;
import 'package:chess_auto_prep/utils/ease_utils.dart'
    show expectedCpFromWinProb;
import 'package:chess_auto_prep/utils/movetext_builder.dart';
import 'package:chess_auto_prep/utils/pgn_comment_utils.dart';
import 'package:chess_auto_prep/utils/pgn_nags.dart';

import '../support/props.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

String _pgn(Map<String, String> headers, String movetext) {
  final buf = StringBuffer();
  headers.forEach((k, v) {
    buf.write('[$k "${v.replaceAll('\\', r'\\').replaceAll('"', r'\"')}"]\n');
  });
  buf.write('\n$movetext\n');
  return buf.toString();
}

List<PgnNodeData> _mainline(String pgn) =>
    PgnGame.parsePgn(pgn).moves.mainline().toList();

List<String> _sansOf(List<PgnNodeData> nodes) => [for (final n in nodes) n.san];

List<List<int>> _nagsOf(List<PgnNodeData> nodes) => [
  for (final n in nodes) n.nags ?? const <int>[],
];

/// Comment blocks per move, ignoring blank ones — an empty `{}` carries
/// nothing, and [joinComments] already drops them.
List<List<String>> _commentsOf(List<PgnNodeData> nodes) => [
  for (final n in nodes)
    [
      for (final c in n.comments ?? const <String>[])
        if (c.trim().isNotEmpty) c,
    ],
];

List<List<String>> _tokensOf(List<PgnNodeData> nodes) => [
  for (final n in nodes) pgnAnnotationTokens(joinComments(n.comments)),
];

/// Re-serialize a whole parsed game the way every path that rewrites a stored
/// game does: `GameAnalysisController._rebuildMovetext` and the comment
/// editor's `ViewerGameModel.buildAnnotatedMovetext` both come through
/// [buildGameMovetext], and both land in the same slot of the same file.
String _resave(PgnGame<PgnNodeData> game) => _pgn(
  Map<String, String>.from(game.headers),
  buildGameMovetext(
    moves: game.moves,
    comments: game.comments,
    fen: game.headers['FEN'],
    result: game.headers['Result'],
  ),
);

final _numberLabelRe = RegExp(r'\d+\.(?:\.\.)?');

/// A move number and the space that follows it, which compact mode drops.
final _labelWithSpaceRe = RegExp(r'(\d+\.(?:\.\.)?) ');

List<String> _numberLabels(String movetext) =>
    _numberLabelRe.allMatches(movetext).map((m) => m[0]!).toList();

// ---------------------------------------------------------------------------
// Generators built on top of the kit
// ---------------------------------------------------------------------------

/// A line of legal moves together with the FEN it starts from, so numbering
/// can be checked from any ply and either colour to move.
class _Suffix {
  const _Suffix(this.fen, this.sans);
  final String fen;
  final List<String> sans;

  @override
  String toString() => '_Suffix($fen | ${sans.join(' ')})';
}

Generator<_Suffix> _suffixes() => Generator(
  (r) {
    Position pos = Chess.initial;
    final cut = r.between(0, 14);
    for (var i = 0; i < cut; i++) {
      if (pos.isGameOver) break;
      final moves = legalMovesOf(pos);
      if (moves.isEmpty) break;
      pos = pos.makeSan(r.pick(moves)).$1;
    }
    return _Suffix(pos.fen, playRandomLine(r, pos, r.between(1, 10)));
  },
  shrinker: (s) sync* {
    if (s.sans.length > 1) {
      yield _Suffix(s.fen, s.sans.take(1).toList());
      yield _Suffix(s.fen, s.sans.take(s.sans.length - 1).toList());
    }
  },
);

/// A move list with null-move tokens mixed in, plus the ply the list starts
/// on. Null moves are text-level only here — the serializer never replays
/// them.
class _NullLine {
  const _NullLine(this.sans, this.startMoveNumber, this.whiteFirst);
  final List<String> sans;
  final int startMoveNumber;
  final bool whiteFirst;

  @override
  String toString() =>
      '_NullLine(${sans.join(' ')} @ $startMoveNumber'
      '${whiteFirst ? 'w' : 'b'})';
}

Generator<_NullLine> _nullLines() => Generator(
  (r) {
    final line = playRandomLine(r, Chess.initial, r.between(1, 12));
    final out = <String>[];
    for (final san in line) {
      if (r.chance(25)) out.add(r.pick(const ['--', 'Z0', '0000', '@@@@']));
      out.add(san);
    }
    if (r.chance(20)) out.add(r.pick(const ['--', 'Z0']));
    return _NullLine(out, r.between(1, 40), r.nextBool());
  },
  shrinker: (l) sync* {
    if (l.sans.length > 1) {
      yield _NullLine(
        l.sans.take(l.sans.length - 1).toList(),
        l.startMoveNumber,
        l.whiteFirst,
      );
      yield _NullLine(l.sans.skip(1).toList(), l.startMoveNumber, l.whiteFirst);
    }
    if (l.startMoveNumber != 1) yield _NullLine(l.sans, 1, l.whiteFirst);
    if (!l.whiteFirst) yield _NullLine(l.sans, l.startMoveNumber, true);
  },
);

/// One engine score plus the comment it has to be written into.
class _EvalCase {
  const _EvalCase(this.cp, this.mate, this.depth, this.comment);
  final int? cp;
  final int? mate;
  final int? depth;
  final String comment;

  @override
  String toString() =>
      '_EvalCase(cp: $cp, mate: $mate, depth: $depth, into: "$comment")';
}

Generator<_EvalCase> _evalCases() => Generator(
  (r) {
    final isMate = r.chance(30);
    return _EvalCase(
      isMate ? null : r.between(-3000, 3000),
      isMate ? r.between(-30, 30) : null,
      r.chance(60) ? r.between(1, 60) : null,
      comments.sample(r),
    );
  },
  shrinker: (e) sync* {
    if (e.comment.isNotEmpty) yield _EvalCase(e.cp, e.mate, e.depth, '');
    if (e.depth != null) yield _EvalCase(e.cp, e.mate, null, e.comment);
    if (e.cp != null && e.cp != 0) yield _EvalCase(0, null, e.depth, e.comment);
    if (e.mate != null && e.mate != 1) {
      yield _EvalCase(null, 1, e.depth, e.comment);
    }
  },
);

/// A principal variation plus the comment it is written into.
class _PvCase {
  const _PvCase(this.pv, this.comment);
  final List<String> pv;
  final String comment;

  @override
  String toString() => '_PvCase(${pv.join(',')} into "$comment")';
}

Generator<_PvCase> _pvCases() => Generator(
  (r) => _PvCase(
    playRandomLine(r, Chess.initial, r.between(1, 8)),
    comments.sample(r),
  ),
  shrinker: (c) sync* {
    if (c.comment.isNotEmpty) yield _PvCase(c.pv, '');
    if (c.pv.length > 1) yield _PvCase(c.pv.take(1).toList(), c.comment);
  },
);

/// A NAG list and the verdict about to be toggled on it.
Generator<(List<int>, int)> _toggleCases() => Generator(
  (r) => (nagSets.sample(r), r.between(1, 6)),
  shrinker: (v) sync* {
    if (v.$1.isNotEmpty) yield (const <int>[], v.$2);
    if (v.$2 != 1) yield (v.$1, 1);
  },
);

/// What the build pipeline knows about one move, in the shapes it actually
/// emits: every field optional, probabilities in [0, 1], evals in centipawns.
Generator<MoveAnnotation> _annotations() => Generator(
  (r) => MoveAnnotation(
    likelihood: r.chance(70) ? r.nextDouble() : null,
    likelihoodSource: r.chance(70) ? r.pick(MoveLikelihoodSource.values) : null,
    gameCount: r.chance(50) ? r.between(1, 500000) : null,
    practicalScore: r.chance(50) ? r.nextDouble() : null,
    evalCp: r.chance(70) ? r.between(-2000, 2000) : null,
    expectimaxValue: r.chance(50) ? r.nextDouble() : null,
    opponentEase: r.chance(40) ? r.nextDouble() : null,
    myEase: r.chance(40) ? r.nextDouble() : null,
    isOnlyMove: r.chance(25),
    onlyMoveLeadCp: r.chance(50) ? r.between(20, 600) : null,
    lastPlayedYear: r.chance(40) ? r.between(1850, 2026) : null,
    note: r.chance(25) ? 'Book ends here; the engine takes over.' : null,
    transposesTo: r.chance(25)
        ? playRandomLine(r, Chess.initial, r.between(1, 5))
        : null,
  ),
  shrinker: (a) sync* {
    if (a.note != null) yield _without(a, note: true);
    if (a.transposesTo != null) yield _without(a, transposes: true);
    if (a.isOnlyMove) yield _without(a, onlyMove: true);
  },
);

/// A copy of [a] with one carrier field dropped, for shrinking.
MoveAnnotation _without(
  MoveAnnotation a, {
  bool note = false,
  bool transposes = false,
  bool onlyMove = false,
}) => MoveAnnotation(
  likelihood: a.likelihood,
  likelihoodSource: a.likelihoodSource,
  gameCount: a.gameCount,
  practicalScore: a.practicalScore,
  evalCp: a.evalCp,
  expectimaxValue: a.expectimaxValue,
  opponentEase: a.opponentEase,
  myEase: a.myEase,
  isOnlyMove: onlyMove ? false : a.isOnlyMove,
  onlyMoveLeadCp: a.onlyMoveLeadCp,
  lastPlayedYear: a.lastPlayedYear,
  note: note ? null : a.note,
  transposesTo: transposes ? null : a.transposesTo,
);

void main() {
  // -------------------------------------------------------------------------
  group('movetext round-trip', () {
    forAll(
      'parse → serialize → parse keeps every move, NAG and comment',
      annotatedGames(
        maxPlies: 14,
        withVariations: false,
        withStartingComments: false,
        withFurniture: false,
      ),
      (spec) {
        final first = PgnGame.parsePgn(spec.render());
        final firstMainline = first.moves.mainline().toList();

        final rebuilt = _resave(first);
        final second = _mainline(rebuilt);

        expect(_sansOf(second), _sansOf(firstMainline), reason: 'moves');
        expect(_nagsOf(second), _nagsOf(firstMainline), reason: 'NAGs');
        expect(_commentsOf(second), _commentsOf(firstMainline), reason: 'text');
      },
    );

    forAll(
      'serializing twice is a fixed point (the second parse equals the first)',
      annotatedGames(
        maxPlies: 14,
        withVariations: false,
        withStartingComments: false,
        withFurniture: false,
      ),
      (spec) {
        final first = PgnGame.parsePgn(spec.render());
        final once = _resave(first);
        final twice = _resave(PgnGame.parsePgn(once));
        expect(twice, once);
      },
    );

    forAll(
      'machine tokens survive an edit of the comment prose and a re-save',
      annotatedGames(maxPlies: 12, withFurniture: false),
      (spec) {
        final game = PgnGame.parsePgn(spec.render());
        final mainline = game.moves.mainline().toList();
        final before = _tokensOf(mainline);

        // What the comment editor does: show the prose, take the edit, put
        // the machine tokens back, store one block.
        for (final node in mainline) {
          final raw = joinComments(node.comments);
          final edited = mergeCommentProse(
            raw,
            '${commentProse(raw)} rewritten by hand'.trim(),
          );
          node.comments = [edited];
        }

        final after = _tokensOf(_mainline(_resave(game)));
        expect(after, before);
      },
    );
  });

  // -------------------------------------------------------------------------
  group('comment editing', () {
    forAll('editing prose never disturbs the machine tokens', comments, (c) {
      final prose = commentProse(c);
      final merged = mergeCommentProse(c, prose);

      expect(pgnAnnotationTokens(merged), pgnAnnotationTokens(c));
      expect(commentProse(merged), prose);
      expect(mergeCommentProse(merged, commentProse(merged)), merged);
    });

    forAll('a replaced prose is what comes back out', comments, (c) {
      const typed = 'a completely new note (with brackets [1] and a ; too)';
      final merged = mergeCommentProse(c, typed);
      expect(pgnAnnotationTokens(merged), pgnAnnotationTokens(c));
      expect(commentProse(merged), typed);
    });

    forAll('clearing the prose keeps the tokens', comments, (c) {
      final merged = mergeCommentProse(c, '');
      expect(pgnAnnotationTokens(merged), pgnAnnotationTokens(c));
      expect(commentProse(merged), '');
    });

    forAll('stripping tokens is a fixed point', comments, (c) {
      expect(commentProse(commentProse(c)), commentProse(c));
      expect(pgnAnnotationTokens(commentProse(c)), isEmpty);
    });

    forAll('the display filter is a fixed point', comments, (c) {
      final once = filterDisplayComment(c);
      expect(filterDisplayComment(once), once);
      expect(pgnAnnotationTokens(once), isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  group('engine tokens', () {
    forAll('an eval survives being written into any comment', _evalCases(), (
      e,
    ) {
      final value = formatEvalCommentValue(
        scoreCp: e.cp,
        scoreMate: e.mate,
        depth: e.depth,
      );
      final written = setEvalInComment(e.comment, value);
      final read = parseEvalComment(written);

      expect(read, isNotNull, reason: 'no [%eval] came back out');
      expect(read!.cp, e.cp);
      expect(read.mate, e.mate);
      expect(read.depth, e.depth);

      // Everything else the comment carried is still there, in order.
      bool notEval(String t) => !t.startsWith('[%eval');
      expect(
        pgnAnnotationTokens(written).where(notEval).toList(),
        pgnAnnotationTokens(e.comment).where(notEval).toList(),
      );
      expect(commentProse(written), commentProse(e.comment));

      // Writing the same score again changes nothing.
      expect(setEvalInComment(written, value), written);
    });

    forAll('a pv survives being written into any comment', _pvCases(), (c) {
      final written = setPvInComment(c.comment, c.pv);
      expect(parsePvComment(written), c.pv);

      bool notPv(String t) => !t.startsWith('[%pv');
      expect(
        pgnAnnotationTokens(written).where(notPv).toList(),
        pgnAnnotationTokens(c.comment).where(notPv).toList(),
      );
      expect(commentProse(written), commentProse(c.comment));
      expect(setPvInComment(written, c.pv), written);
    });

    forAll('an eval and a pv do not evict each other', _evalCases(), (e) {
      final value = formatEvalCommentValue(
        scoreCp: e.cp,
        scoreMate: e.mate,
        depth: e.depth,
      );
      final pv = ['Nf3', 'Nc6', 'Bb5'];
      final both = setPvInComment(setEvalInComment(e.comment, value), pv);
      final read = parseEvalComment(both);

      expect(read?.cp, e.cp);
      expect(read?.mate, e.mate);
      expect(read?.depth, e.depth);
      expect(parsePvComment(both), pv);
      // A clock the game arrived with is what the tempo tags read later.
      expect(
        pgnAnnotationTokens(both).where((t) => t.startsWith('[%clk')).toList(),
        pgnAnnotationTokens(
          e.comment,
        ).where((t) => t.startsWith('[%clk')).toList(),
      );
    });
  });

  // -------------------------------------------------------------------------
  group('numbered movetext', () {
    forAll(
      'numbering from any ply and either colour agrees with dartchess',
      _suffixes(),
      (s) {
        final setup = Setup.parseFen(s.fen);
        final ours = buildNumberedMovetext(
          s.sans,
          startMoveNumber: setup.fullmoves,
          whiteToMoveFirst: setup.turn == Side.white,
        );

        // Oracle: dartchess derives the ply from the FEN header itself.
        final root = PgnNode<PgnNodeData>();
        PgnNode<PgnNodeData> node = root;
        for (final san in s.sans) {
          final child = PgnChildNode(PgnNodeData(san: san));
          node.children.add(child);
          node = child;
        }
        final theirs = PgnGame(
          headers: {'FEN': s.fen, 'SetUp': '1', 'Result': '*'},
          moves: root,
          comments: const [],
        ).makePgn();

        expect(_numberLabels(ours), _numberLabels(theirs.split('\n\n').last));
      },
    );

    forAll('the moves come back out of the numbered text', _suffixes(), (s) {
      final setup = Setup.parseFen(s.fen);
      final text = buildNumberedMovetext(
        s.sans,
        startMoveNumber: setup.fullmoves,
        whiteToMoveFirst: setup.turn == Side.white,
      );
      final pgn = _pgn({'FEN': s.fen, 'SetUp': '1'}, '$text *');
      expect(mainlineSansOf(pgn), s.sans);
      expect(_sansOf(_mainline(pgn)), s.sans);
    });

    forAll(
      'a null move passes the turn without taking a number',
      _nullLines(),
      (l) {
        final text = buildNumberedMovetext(
          l.sans,
          startMoveNumber: l.startMoveNumber,
          whiteToMoveFirst: l.whiteFirst,
        );

        for (final token in const ['--', 'Z0', '0000', '@@@@']) {
          expect(text.contains(token), isFalse, reason: 'null move leaked');
        }

        // The one home of the dot rule is `moveNumberLabel`; the serializer has
        // to agree with it for every move it does emit.
        final offset = l.whiteFirst ? 0 : 1;
        var first = true;
        for (var i = 0; i < l.sans.length; i++) {
          if (isNullMoveSan(l.sans[i])) continue;
          final labelled = formatMoveAtPly(
            i + offset,
            l.sans[i],
            startMoveNumber: l.startMoveNumber,
          );
          if (first) {
            expect(text.startsWith(labelled), isTrue, reason: 'first move');
            first = false;
          } else if ((i + offset).isEven) {
            expect(text.contains(labelled), isTrue, reason: 'white move $i');
          }
        }
        if (first) expect(text, isEmpty, reason: 'only null moves');
      },
    );

    forAll(
      'compact numbering differs from spaced only by that space',
      _nullLines(),
      (l) {
        final spaced = buildNumberedMovetext(
          l.sans,
          startMoveNumber: l.startMoveNumber,
          whiteToMoveFirst: l.whiteFirst,
        );
        final compact = buildNumberedMovetext(
          l.sans,
          startMoveNumber: l.startMoveNumber,
          whiteToMoveFirst: l.whiteFirst,
          compact: true,
        );
        expect(
          compact,
          spaced.replaceAllMapped(_labelWithSpaceRe, (m) => m[1]!),
        );
        expect(
          compact.replaceAll(' ', ''),
          spaced.replaceAll(' ', ''),
          reason: 'compact mode may only drop spaces',
        );
      },
    );
  });

  // -------------------------------------------------------------------------
  group('NAGs', () {
    forAll('every NAG reaches the reader as a glyph', nagSets, (nags) {
      final suffix = allNagSuffix(nags);
      expect(suffix.isEmpty, nags.isEmpty);
      var width = 0;
      for (final n in nags) {
        final symbol = nagSymbol(n);
        expect(symbol, isNotEmpty, reason: 'NAG \$$n has no glyph');
        expect(suffix.contains(symbol), isTrue, reason: 'NAG \$$n swallowed');
        width += symbol.length;
      }
      expect(suffix.length, width, reason: 'a glyph was dropped or invented');
    });

    forAll('an unknown NAG still shows its number', ints(0, 400), (id) {
      expect(nagSymbol(id), isNotEmpty);
      if (nagInfoById(id) == null && !kPositionNagSymbols.containsKey(id)) {
        expect(nagSymbol(id).contains('$id'), isTrue);
      }
      if (nagInfoById(id) != null) {
        expect(nagColor(id), nagInfoById(id)!.color);
        expect(nagColor(id) == nagColor(999), isFalse, reason: 'fallback ink');
      }
    });

    forAll('the quality glyphs are the editable subset', nagSets, (nags) {
      final quality = qualityNagSuffix(nags);
      for (final n in nags) {
        if (n >= 1 && n <= 6) {
          expect(quality.contains(nagSymbol(n)), isTrue);
        }
      }
      final primary = primaryQualityNag(nags);
      if (primary != null) expect(quality.startsWith(nagSymbol(primary)), true);
    });

    forAll('toggling a verdict keeps everything else', _toggleCases(), (input) {
      final (current, id) = input;
      final toggled = toggleQualityNag(current, id);

      final others = current.where((n) => n < 1 || n > 6).toList();
      expect(
        toggled.where((n) => n < 1 || n > 6).toList(),
        others,
        reason: 'positional NAGs must survive a verdict change',
      );
      expect(
        toggled.where((n) => n >= 1 && n <= 6).length,
        lessThanOrEqualTo(1),
        reason: 'verdicts are mutually exclusive',
      );
      expect(primaryQualityNag(toggled), current.contains(id) ? null : id);
      // Toggling settles into a two-cycle immediately.
      expect(
        toggleQualityNag(toggleQualityNag(toggled, id), id),
        toggled,
        reason: 'toggle is not an involution after the first press',
      );
    });

    forAll(
      'NAGs written into movetext come back with the same glyphs',
      annotatedGames(
        maxPlies: 10,
        withVariations: false,
        withStartingComments: false,
        withFurniture: false,
      ),
      (spec) {
        final game = PgnGame.parsePgn(spec.render());
        final mainline = game.moves.mainline().toList();
        final glyphs = [for (final n in mainline) allNagSuffix(n.nags)];
        final back = _mainline(_resave(game));
        expect([for (final n in back) allNagSuffix(n.nags)], glyphs);
      },
    );
  });

  // -------------------------------------------------------------------------
  group('generated repertoire annotations', () {
    forAll(
      'what the exporter writes is what MoveMetrics reads back',
      _annotations(),
      (a) {
        final comment = a.toPgnComment(MoveAnnotationDetail.full);
        if (comment == null) return; // nothing to say about this move
        final m = MoveMetrics.parse(comment);

        expect(m.evalCp, a.evalCp, reason: 'eval');
        expect(
          m.expectimaxCp,
          a.expectimaxValue == null
              ? null
              : expectedCpFromWinProb(a.expectimaxValue!),
          reason: 'expectimax',
        );
        expect(m.isOnlyMove, a.isOnlyMove, reason: 'only move');
        expect(m.lastPlayedYear, a.lastPlayedYear, reason: 'last played');
        expect(m.gameCount, a.gameCount, reason: 'games');
        _closeTo(m.myEase, a.myEase, 0.005, 'my ease');
        _closeTo(m.opponentEase, a.opponentEase, 0.005, 'their ease');
        _closeTo(m.practicalScore, a.practicalScore, 0.0006, 'score');
        if (a.likelihood != null && a.likelihoodSource != null) {
          expect(m.likelihoodSource, a.likelihoodSource);
          _closeTo(m.likelihood, a.likelihood, 0.0006, 'likelihood');
        }
        expect(parseTransposesToken(comment), a.transposesTo);
      },
    );

    forAll(
      'the reader is left with the prose and nothing else',
      _annotations(),
      (a) {
        final comment = a.toPgnComment(MoveAnnotationDetail.full);
        if (comment == null) return;
        final prose = commentProse(comment);
        expect(prose.contains('[%'), isFalse, reason: 'a raw token leaked');
        if (a.note != null) expect(prose.contains(a.note!), isTrue);
        if (a.explanation.isNotEmpty) {
          expect(prose.contains(a.explanation), isTrue, reason: 'lost the why');
        }
      },
    );

    forAll(
      'turning the metrics off drops numbers, never the prose',
      _annotations(),
      (a) {
        final light = a.toPgnComment(MoveAnnotationDetail.likelihood);
        if (light == null) return;
        final m = MoveMetrics.parse(light);
        expect(m.evalCp, isNull);
        expect(m.expectimaxCp, isNull);
        expect(m.gameCount, isNull);
        if (a.note != null) expect(commentProse(light).contains(a.note!), true);
      },
    );
  });

  // -------------------------------------------------------------------------
  group('the parsing service', () {
    forAll(
      'mainlineSansOf reads exactly what dartchess reads',
      annotatedGames(maxPlies: 18),
      (spec) {
        final text = spec.render();
        expect(mainlineSansOf(text), _sansOf(_mainline(text)));
      },
    );

    forAll(
      'headers survive a round trip through the file',
      annotatedGames(maxPlies: 6),
      (spec) {
        final text = spec.render();
        final block = extractHeaderBlock(text);
        final parsed = PgnGame.parsePgn(text).headers;
        for (final entry in block.entries) {
          // `Result` is the one header dartchess overwrites, from the game
          // terminator at the end of the movetext.
          if (entry.key == 'Result') continue;
          expect(parsed[entry.key], entry.value, reason: entry.key);
        }
      },
    );

    forAll(
      'splitting a concatenation of games gives the games back',
      listOf(annotatedGames(maxPlies: 8, withFurniture: false), min: 1, max: 4),
      (specs) {
        final text = specs.map((s) => s.render()).join('\n');
        final chunks = splitPgnIntoGames(text);

        expect(chunks.length, specs.length, reason: 'chunk count');
        expect(countPgnGames(text), specs.length, reason: 'countPgnGames');
        for (var i = 0; i < specs.length; i++) {
          expect(
            mainlineSansOf(chunks[i]),
            specs[i].sans,
            reason: 'moves of game $i',
          );
          expect(
            extractHeaderBlock(chunks[i])['Event'],
            specs[i].headers['Event'],
            reason: 'headers of game $i',
          );
        }
      },
    );
  });

  // -------------------------------------------------------------------------
  // Regression: analysing a game used to delete the user's sidelines.
  //
  // `GameAnalysisController._rebuildMovetext` re-serialized from
  // `moves.mainline()` through `buildMovetext`, which loses two things the
  // parser found — the game's own opening comment (`PgnGame.comments`,
  // machine tokens and all) and every variation. That text is not a preview:
  // the viewer splices it back over the stored game and writes the file
  // (`PgnViewerController.persistMoveCommentsFor`), so a review pass deleted
  // sidelines from the reader's own PGN. Both save paths now go through
  // `buildGameMovetext` (`_resave` here), which is what the comment editor's
  // `ViewerGameModel.buildAnnotatedMovetext` always used.
  group('a re-save is lossless', () {
    test('minimal counterexample: an intro comment and a sideline', () {
      const headers = '[Event "a"]\n[Result "1-0"]\n\n';
      const pgn =
          '$headers{intro [%clk 0:05:00]} 1. e4 (1. d4 d5) e5 2. Nf3 1-0\n';
      final game = PgnGame.parsePgn(pgn);
      final back = PgnGame.parsePgn(_resave(game));

      expect(
        back.comments,
        game.comments,
        reason: 'the [%clk] in the game comment was dropped',
      );
      expect(
        _nodeCount(back.moves),
        _nodeCount(game.moves),
        reason: 'the sideline was dropped',
      );
    });

    forAll(
      'a re-save keeps the game comment and the variations',
      annotatedGames(maxPlies: 8, withFurniture: false),
      (spec) {
        final game = PgnGame.parsePgn(spec.render());
        final back = PgnGame.parsePgn(_resave(game));
        expect(
          [
            for (final c in back.comments)
              if (c.trim().isNotEmpty) c,
          ],
          [
            for (final c in game.comments)
              if (c.trim().isNotEmpty) c,
          ],
          reason: 'the game comment',
        );
        expect(_nodeCount(back.moves), _nodeCount(game.moves), reason: 'RAVs');
      },
    );
  });
}

/// Every move node in the tree, mainline and variations alike.
int _nodeCount(PgnNode<PgnNodeData> root) {
  var count = 0;
  final stack = [root];
  while (stack.isNotEmpty) {
    final node = stack.removeLast();
    count += node.children.length;
    stack.addAll(node.children);
  }
  return count;
}

/// `expect(a, closeTo(b))` that also accepts "both absent".
void _closeTo(double? actual, double? expected, double epsilon, String what) {
  if (expected == null) {
    expect(actual, isNull, reason: what);
    return;
  }
  expect(actual, isNotNull, reason: what);
  expect(actual, closeTo(expected, epsilon), reason: what);
}

/// Input-sanitization / malformed-input resilience tests for the PGN parsing
/// layer ([pgn_parsing_service] + [pgn_tree_core]).
///
/// The contract these tests pin down: every public parsing entrypoint must,
/// for *any* input, either
///   (a) produce the correct structure, or
///   (b) fail gracefully — return empty / null / a caught fallback —
/// but NEVER hang, NEVER corrupt state, and NEVER throw an uncaught error.
///
/// The underlying dartchess `PgnGame.parsePgn` is intentionally very lenient
/// (it fills default headers and skips unparseable tokens rather than
/// throwing); the app-level wrappers here additionally wrap it in try/catch.
/// Where behaviour is surprising-but-current it is captured with a NOTE so a
/// future refactor can't silently change it.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/models/opening_tree.dart';
import 'package:chess_auto_prep/services/pgn_parsing_service.dart';
import 'package:chess_auto_prep/services/pgn_tree_core.dart';

/// Every string-based splitter/counter/extractor exercised in one place, so a
/// new "must not throw on anything" case can be added to a single list.
void expectAllStringHelpersSurvive(String input, {String? because}) {
  final reason = because ?? 'input: ${input.length} chars';
  expect(() => splitPgnIntoGames(input), returnsNormally, reason: reason);
  expect(() => countPgnGames(input), returnsNormally, reason: reason);
  expect(() => countPgnGamesFast(input), returnsNormally, reason: reason);
  expect(() => extractHeaders(input), returnsNormally, reason: reason);
  expect(() => extractRepertoireColor(input), returnsNormally, reason: reason);
  expect(() => stripBom(input), returnsNormally, reason: reason);
  expect(() => parseSequenceGroups(input), returnsNormally, reason: reason);
  expect(() => parseTargetFen(input), returnsNormally, reason: reason);
  // The single-game replay helpers must also stay caught.
  expect(
    () => gamePassesThroughFen(const {}, input, 'anything'),
    returnsNormally,
    reason: reason,
  );
  expect(
    () => gameMatchesSequence(input, const [
      ['e4'],
    ], 4),
    returnsNormally,
    reason: reason,
  );
  expect(
    () => buildFenIndex([(headers: const {}, pgnText: input)]),
    returnsNormally,
    reason: reason,
  );
}

void main() {
  // ── Valid PGN — happy path ─────────────────────────────────────────────────
  group('valid PGN (happy path)', () {
    const twoRealGames = '''
[Event "Sicilian"]
[Site "?"]
[White "Alice"]
[Black "Bob"]
[Result "1-0"]

1. e4 c5 2. Nf3 d6 3. d4 cxd4 4. Nxd4 Nf6 5. Nc3 a6 1-0

[Event "QGD"]
[White "Carol"]
[Black "Dave"]
[Result "0-1"]

1. d4 d5 2. c4 e6 3. Nc3 Nf6 0-1
''';

    test('splits into two games with correct headers', () {
      final games = splitPgnIntoGames(twoRealGames);
      expect(games, hasLength(2));
      expect(extractHeaders(games[0])['White'], 'Alice');
      expect(extractHeaders(games[1])['Black'], 'Dave');
      expect(countPgnGames(twoRealGames), 2);
      expect(countPgnGamesFast(twoRealGames), 2);
    });

    test('mainline of a real game replays cleanly into a tree', () {
      final tree = OpeningTree();
      walkMainlineIntoTree(
        tree: tree,
        game: PgnGame.parsePgn('1. e4 c5 2. Nf3 d6 3. d4 cxd4 4. Nxd4 Nf6 1-0'),
        userResult: 1.0,
        maxDepth: 30,
      );
      expect(tree.root.children['e4'], isNotNull);
      final line = tree.root.children['e4']!.children['c5']!;
      expect(line.children['Nf3'], isNotNull);
    });

    test('variations, NAGs and comments do not derail the mainline', () {
      // RAV `(...)`, NAG `$1`, and `{...}` comment are all present.
      const pgn =
          '1. e4 e5 \$1 {good} 2. Nf3 (2. f4 exf4) Nc6 {develops} 3. Bb5 *';
      final game = PgnGame.parsePgn(pgn);
      final mainline = game.moves.mainline().map((n) => n.san).toList();
      expect(mainline, ['e4', 'e5', 'Nf3', 'Nc6', 'Bb5']);
    });

    test('SetUp/FEN header sets a custom start position', () {
      const fen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR b KQkq - 0 1';
      final game = PgnGame.parsePgn('[SetUp "1"]\n[FEN "$fen"]\n\n1... e5 *');
      expect(startPositionFromGame(game).fen, contains(' b '));
    });
  });

  // ── Malformed movetext ─────────────────────────────────────────────────────
  group('malformed movetext degrades gracefully', () {
    // NOTE: dartchess never throws on any of these; a `{`/`(` that is never
    // closed simply swallows the remainder of the movetext. The app relies on
    // exactly this leniency (see MEMORY: "PGN display leniency").
    const malformed = <String, String>{
      'unbalanced open brace': '1. e4 {unterminated comment e5 2. Nf3 *',
      'unbalanced close brace': '1. e4 e5} 2. Nf3 *',
      'unbalanced open paren': '1. e4 (1... c5 e5 2. Nf3 *',
      'unbalanced close paren': '1. e4 e5) 2. Nf3 *',
      'missing move numbers': 'e4 e5 Nf3 Nc6 *',
      'illegal SAN token': '1. e4 Zz9 2. Nf3 *',
      'truncated mid-move': '1. e4 e5 2. Nf',
      'truncated mid-number': '1. e4 e5 2.',
      'stray clk/eval tokens': '1. e4 {[%clk 0:03:00]} e5 {[%eval -0.3]} *',
      'doubled spaces': '1.  e4   e5    2.  Nf3  *',
      'trailing garbage after result': '1. e4 e5 * blah blah !@#\$%',
      'only a result token': '*',
      'bare NAGs': '1. e4 \$1 \$2 \$255 e5 *',
      'nested unbalanced': '1. e4 ({[( e5 *',
    };

    malformed.forEach((label, pgn) {
      test('does not throw or hang: $label', () {
        expectAllStringHelpersSurvive(pgn, because: label);
        // The raw dartchess entrypoint the app calls must not throw either.
        expect(() => PgnGame.parsePgn(pgn), returnsNormally, reason: label);
      });
    });

    test('an unterminated comment swallows the rest of the mainline', () {
      // Documents current behaviour: everything after an unclosed `{` is
      // treated as comment text, so only moves before it survive.
      final game = PgnGame.parsePgn('1. e4 {oops e5 2. Nf3 *');
      expect(game.moves.mainline().map((n) => n.san), ['e4']);
    });

    test('a syntactically-invalid SAN token is skipped, not fatal', () {
      // NOTE: "Zz9" is not valid SAN *syntax*, so dartchess drops the token
      // entirely and keeps parsing — the illegal token never reaches the tree.
      final game = PgnGame.parsePgn('1. e4 Zz9 Nc6 *');
      final sans = game.moves.mainline().map((n) => n.san).toList();
      expect(sans, isNot(contains('Zz9')));
    });

    test('walkMainlineIntoTree stops at the first ILLEGAL (but well-formed) '
        'SAN without throwing', () {
      // "Ke7" is valid SAN syntax but an illegal move; dartchess keeps it in
      // the node stream, and the tree walk halts when parseSan rejects it.
      final tree = OpeningTree();
      expect(
        () => walkMainlineIntoTree(
          tree: tree,
          game: PgnGame.parsePgn('1. e4 Ke7 2. Nf3 *'),
          userResult: 0.5,
          maxDepth: 30,
        ),
        returnsNormally,
      );
      expect(tree.root.children['e4']!.children, isEmpty);
    });

    test('malformed movetext yields no false FEN/sequence matches', () {
      expect(
        gamePassesThroughFen(const {}, '1. e4 {unbalanced', 'nonexistent-fen'),
        isFalse,
      );
      expect(
        gameMatchesSequence('1. e4 {unbalanced', [
          ['Nf3'],
        ], 4),
        isFalse,
      );
    });
  });

  // ── Empty / whitespace / null-ish input ────────────────────────────────────
  group('empty and whitespace-only input', () {
    const blanks = <String, String>{
      'empty string': '',
      'single space': ' ',
      'spaces and tabs': '   \t\t  ',
      'newlines only': '\n\n\n',
      'crlf blanks': '\r\n\r\n',
      'bom only': '﻿',
      'bom + whitespace': '﻿   \n',
    };

    blanks.forEach((label, input) {
      test('all helpers return empty/graceful for $label', () {
        expectAllStringHelpersSurvive(input, because: label);
        expect(splitPgnIntoGames(input), isEmpty, reason: label);
        expect(countPgnGames(input), 0, reason: label);
        expect(countPgnGamesFast(input), 0, reason: label);
        expect(extractHeaders(input), isEmpty, reason: label);
        expect(extractRepertoireColor(input), isNull, reason: label);
      });
    });

    test('parseTargetFen treats null/empty as no target', () {
      expect(parseTargetFen(null), isNull);
      expect(parseTargetFen(''), isNull);
      expect(parseTargetFen('   '), isNull);
    });

    test('parseSequenceGroups treats blank/decoration-only as no groups', () {
      expect(parseSequenceGroups(''), isEmpty);
      expect(parseSequenceGroups('   '), isEmpty);
      expect(parseSequenceGroups('1. 2. 3. *'), isEmpty);
    });
  });

  // ── Boundary / oversized input ─────────────────────────────────────────────
  group('boundary / oversized input terminates without stack overflow', () {
    test(
      'very long single game (2000 plies) parses and bounds by maxDepth',
      () {
        final sb = StringBuffer();
        for (var i = 1; i <= 1000; i++) {
          sb.write('$i. Nf3 Nf6 $i... ');
        }
        final huge = '${sb.toString()}*';
        late PgnGame<PgnNodeData> game;
        expect(() => game = PgnGame.parsePgn(huge), returnsNormally);

        final tree = OpeningTree();
        expect(
          () => walkMainlineIntoTree(
            tree: tree,
            game: game,
            userResult: 1.0,
            maxDepth: 40, // walk must self-limit even on a giant mainline
          ),
          returnsNormally,
        );
        // Depth is capped: no chain longer than maxDepth exists.
        var node = tree.root;
        var depth = 0;
        while (node.children.isNotEmpty) {
          node = node.children.values.first;
          depth++;
          expect(depth, lessThanOrEqualTo(40));
        }
      },
    );

    test('deeply nested variations do not overflow the stack', () {
      final deep = '1. e4 e5 ${'(' * 500}1... c5${')' * 500} *';
      expect(() => PgnGame.parsePgn(deep), returnsNormally);
      expect(
        () => buildFenIndex([(headers: const {}, pgnText: deep)]),
        returnsNormally,
      );
    });

    test('thousands of tiny games split and count in reasonable time', () {
      final sb = StringBuffer();
      for (var i = 0; i < 3000; i++) {
        sb.writeln('[Event "G$i"]');
        sb.writeln('1. e4 *');
        sb.writeln();
      }
      final many = sb.toString();
      final sw = Stopwatch()..start();
      expect(countPgnGamesFast(many), 3000);
      expect(countPgnGames(many), 3000);
      sw.stop();
      // Generous ceiling — asserts termination, not micro-performance.
      expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
    });

    test('sequence matcher with 200 gap-groups terminates', () {
      final pattern = List.filled(200, 'e4').join(' [gap] ');
      final groups = parseSequenceGroups(pattern);
      expect(groups, hasLength(200));
      expect(
        () => gameMatchesSequence('1. e4 e5 2. Nf3 *', groups, 4),
        returnsNormally,
      );
    });
  });

  // ── Line endings / BOM ─────────────────────────────────────────────────────
  group('line endings and BOM', () {
    test('Windows CRLF splits and counts like LF', () {
      const crlf = '[Event "G1"]\r\n1. e4 *\r\n\r\n[Event "G2"]\r\n1. d4 *\r\n';
      expect(splitPgnIntoGames(crlf), hasLength(2));
      expect(countPgnGames(crlf), 2);
      expect(countPgnGamesFast(crlf), 2);
      expect(extractHeaders(crlf.split('\n').first)['Event'], 'G1');
    });

    test('leading BOM is stripped before counting', () {
      const pgn = '﻿[Event "G1"]\n1. e4 *\n\n[Event "G2"]\n1. d4 *';
      expect(stripBom(pgn).startsWith('['), isTrue);
      expect(countPgnGames(pgn), 2);
      expect(countPgnGamesFast(pgn), 2);
    });

    test('classic-Mac CR-only endings collapse to one game (graceful, no '
        'crash)', () {
      // NOTE / minor sanitization gap: splitters key on "\n", so a CR-only
      // ("\r") file — obsolete pre-OSX Mac format — is seen as a single line
      // and reported as ONE game rather than two. It never crashes or hangs;
      // this test pins the current, benign behaviour so a future normaliser
      // (split on \r\n|\r|\n) is a conscious change, not an accident.
      const cr = '[Event "G1"]\r1. e4 *\r\r[Event "G2"]\r1. d4 *\r';
      expect(() => splitPgnIntoGames(cr), returnsNormally);
      expect(splitPgnIntoGames(cr), hasLength(1));
      expect(countPgnGames(cr), 1);
      expect(countPgnGamesFast(cr), 1);
    });
  });

  // ── Unicode / special characters ───────────────────────────────────────────
  group('unicode and special characters', () {
    test('emoji / RTL / CJK in headers are preserved verbatim', () {
      const pgn = '[Event "🔥 Blitz ♟ العربية 中文"]\n[White "Ćelïk"]\n1. e4 *';
      final headers = extractHeaders(pgn);
      expect(headers['Event'], '🔥 Blitz ♟ العربية 中文');
      expect(headers['White'], 'Ćelïk');
    });

    test('brackets and percent signs inside a header value do not break the '
        'regex', () {
      // The value contains '[', ']' and '%' — none may terminate the match.
      const pgn = '[Site "room [A] 100% legit"]\n1. e4 *';
      final headers = extractHeaders(pgn);
      expect(headers['Site'], 'room [A] 100% legit');
    });

    test('unicode-laden comments and headers still parse a clean mainline', () {
      const pgn = '[Event "🏆"]\n\n1. e4 {🔥 great! ♜} e5 {العربية} 2. Nf3 *';
      final game = PgnGame.parsePgn(pgn);
      expect(game.moves.mainline().map((n) => n.san), ['e4', 'e5', 'Nf3']);
      expectAllStringHelpersSurvive(pgn, because: 'unicode movetext');
    });

    test('emoji-only movetext produces no false matches and no crash', () {
      expectAllStringHelpersSurvive('🔥♟🏆', because: 'emoji-only');
      expect(parseTargetFen('🔥♟🏆'), isNull);
    });
  });

  // ── Header edge cases ──────────────────────────────────────────────────────
  group('header edge cases', () {
    test('missing Seven-Tag-Roster tags — extractHeaders returns only what is '
        'present', () {
      const pgn = '[White "Solo"]\n\n1. e4 *';
      final headers = extractHeaders(pgn);
      expect(headers, {'White': 'Solo'});
      expect(headers.containsKey('Black'), isFalse);
      expect(headers.containsKey('Result'), isFalse);
    });

    test('duplicate tags — last value wins in extractHeaders', () {
      const pgn = '[Event "First"]\n[Event "Second"]\n\n1. e4 *';
      expect(extractHeaders(pgn)['Event'], 'Second');
    });

    test('unterminated header [Key "Value] is ignored, not partially '
        'captured', () {
      // Missing closing quote+bracket → the pair regex simply does not match,
      // so a malformed header cannot inject a garbage value.
      const pgn = '[Event "unterminated]\n[White "Real"]\n\n1. e4 *';
      final headers = extractHeaders(pgn);
      expect(headers.containsKey('Event'), isFalse);
      expect(headers['White'], 'Real');
    });

    test('injection-like header values are stored as inert text', () {
      const pgn =
          '[White "\\"]; DROP TABLE games;--"]\n[Black "<script>x</script>"]'
          '\n\n1. e4 *';
      // Must not throw and must not mis-key; values stay opaque strings.
      expect(() => extractHeaders(pgn), returnsNormally);
      final headers = extractHeaders(pgn);
      expect(headers['Black'], '<script>x</script>');
    });

    test('empty header value is captured as an empty string', () {
      const pgn = '[Event ""]\n[White "A"]\n\n1. e4 *';
      expect(extractHeaders(pgn)['Event'], '');
    });

    test('extractRepertoireColor ignores garbage color and stops at Event', () {
      expect(extractRepertoireColor('// Color: purple\n1. e4'), isNull);
      expect(extractRepertoireColor('// Color: White\n[Event ""]'), 'white');
      expect(
        extractRepertoireColor('[Event "x"]\n// Color: Black'),
        isNull,
        reason: 'must stop scanning at the first [Event',
      );
    });
  });

  // ── FEN / target-position parsing ──────────────────────────────────────────
  group('FEN and target-position parsing', () {
    test('malformed FEN input returns null instead of throwing', () {
      for (final bad in [
        'not/a/fen/at/all w - -',
        '8/8/8/8/8/8/8/8 w - - 0 1', // no kings — illegal setup
        'rnbqkbnr/pppppppp w - - 0 1', // too few ranks
        'zzz/zzz w - - 0 1',
      ]) {
        expect(parseTargetFen(bad), isNull, reason: bad);
      }
    });

    // NOTE: a board-only string (no side-to-move / castling fields) is
    // accepted by dartchess and normalized to just the board — it is NOT
    // rejected. Pinned so the leniency is a conscious contract.
    test('board-only FEN is accepted (lenient), not rejected', () {
      expect(
        parseTargetFen('rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR'),
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR',
      );
    });

    test('valid FEN normalizes to a 4-field target', () {
      final fen = parseTargetFen(
        'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1',
      );
      expect(fen, isNotNull);
      expect(fen!.split(' '), hasLength(4));
    });

    test('SAN sequence with a well-formed but illegal move returns null', () {
      // Tokens that are valid SAN *syntax* but illegal moves are rejected
      // cleanly (parseSan returns null → parseTargetFen returns null).
      expect(parseTargetFen('e4 e5 Ke2 Ke7 e9'), isNull);
      expect(parseTargetFen('O-O-O-O'), isNull);
    });

    // ─────────────────────────────────────────────────────────────────────────
    // REGRESSION GUARD (was a defect; fixed in pgn_parsing_service.dart):
    //
    // parseTargetFen's SAN-sequence branch calls `pos.parseSan(t)` /
    // `pos.play(move)`, and for certain malformed tokens dartchess THROWS a
    // RangeError instead of returning null. The loop is now wrapped in
    // try/catch so any such input returns null (this function's documented
    // "null on invalid input" contract), matching the FEN branch.
    //
    // Reproducers: a token starting with '(' (e.g. pasted movetext containing
    // a variation like "1. e4 (1... c5 ...") or a token starting with 'x'.
    // parseTargetFen backs the position-input box in the slice/filter UI, so
    // these must never crash it.
    // ─────────────────────────────────────────────────────────────────────────
    group('parseTargetFen is robust to throwing SAN tokens', () {
      for (final bad in const ['(', 'e4 (', 'e4 x', '1. e4 (1... c5 e5 *']) {
        test('returns null (no throw) for: "$bad"', () {
          expect(() => parseTargetFen(bad), returnsNormally);
          expect(parseTargetFen(bad), isNull);
        });
      }
    });

    test('startPositionFromGame falls back to initial on a bad FEN header', () {
      final game = PgnGame.parsePgn(
        '[SetUp "1"]\n[FEN "totally-broken"]\n\n1. e4 *',
      );
      expect(startPositionFromGame(game).fen, Chess.initial.fen);
    });
  });

  // ── FEN-index persistence sanitization ─────────────────────────────────────
  group('FEN index (de)serialization sanitization', () {
    test('rejects a truncated / header-less blob', () {
      expect(
        deserializeFenIndex(
          'no-newline-at-all',
          expectedGameCount: 1,
          expectedFileSize: 1,
          expectedModifiedMs: 1,
        ),
        isNull,
      );
    });

    test('rejects a blob whose metadata does not match the current file', () {
      final blob = serializeFenIndex(
        {
          'somefen': [0],
        },
        gameCount: 2,
        fileSize: 100,
        modifiedMs: 5,
      );
      expect(
        deserializeFenIndex(
          blob,
          expectedGameCount: 99, // mismatch → force rebuild
          expectedFileSize: 100,
          expectedModifiedMs: 5,
        ),
        isNull,
      );
    });

    test('rejects a blob referencing an out-of-range game index', () {
      // An index >= gameCount would crash consumers; deserialize returns null.
      expect(
        deserializeFenIndex(
          'FENIDX1 2 10 20\nsomefen\t5\n',
          expectedGameCount: 2,
          expectedFileSize: 10,
          expectedModifiedMs: 20,
        ),
        isNull,
      );
    });

    test('round-trips a well-formed index', () {
      final original = {
        'fen-a': [0, 1],
        'fen-b': [1],
      };
      final blob = serializeFenIndex(
        original,
        gameCount: 2,
        fileSize: 42,
        modifiedMs: 7,
      );
      final restored = deserializeFenIndex(
        blob,
        expectedGameCount: 2,
        expectedFileSize: 42,
        expectedModifiedMs: 7,
      );
      expect(restored, original);
    });
  });

  // ── Isolate-free slice compute on messy games ──────────────────────────────
  group('computeSliceMatches tolerates malformed games', () {
    test('a mix of clean and broken games never throws and skips the broken '
        'ones for FEN lookups', () async {
      final games = <GameRecord>[
        (headers: const {'White': 'A'}, pgnText: '1. e4 e5 *'),
        (headers: const {'White': 'B'}, pgnText: '1. e4 {unbalanced'),
        (headers: const {'White': 'C'}, pgnText: 'total nonsense @@@'),
      ];
      // No filters, no target → all indices pass straight through.
      final all = await computeSliceMatches(
        games: games,
        filters: const [],
        seqGroups: const [],
        seqGap: 4,
      );
      expect(all, [0, 1, 2]);

      // A header filter still evaluates without choking on broken movetext.
      final filtered = await computeSliceMatches(
        games: games,
        filters: const [(field: 'White', mode: MatchMode.contains, value: 'A')],
        seqGroups: const [],
        seqGap: 4,
      );
      expect(filtered, [0]);
    });
  });
}

/// Puzzle set ↔ PGN codec.
///
/// Each puzzle is one PGN "game": `[FEN]`/`[SetUp "1"]` headers, the solution
/// line as the mainline (first move = the solver's move), and the note as a
/// brace comment before the first move.  Human-readable, opens in any chess
/// GUI, and re-imports into a set.
///
/// Since July 2026 this is the *lossless* set format (PGN files replaced the
/// old 20-column CSV): review stats and mistake metadata ride along as
/// custom headers, which any PGN-conformant tool preserves and a plain text
/// editor can modify.  Headers are only written when they carry information,
/// so hand-written puzzle files stay minimal, and every custom header is
/// optional on import (third-party PGN needs nothing beyond `[FEN]` and a
/// mainline).
///
/// Custom headers:
///   GameId, UserMove, MistakeType, OpponentBestResponse — mistake-mining
///     provenance (what you played and how bad it was).
///   ReviewCount, SuccessCount, LastReviewed, TimeToSolve, HintsUsed,
///     StarRating — review stats.
///   SolutionPv — longer engine PV for display, SAN, space-separated
///     (the mainline holds only the trainable line).
///   CorrectLine — raw solution tokens, written *only* when the stored line
///     cannot be converted to SAN (corrupt data); keeps saves lossless.
library;

import 'package:dartchess/dartchess.dart';

import '../models/tactics_position.dart';
import '../models/tactics_session_settings.dart';
import 'pgn_parsing_service.dart'
    show splitPgnIntoGames, extractHeaders, stripBom;
import 'tactics_engine.dart';

String _escapeHeader(String s) =>
    s.replaceAll('\\', '\\\\').replaceAll('"', '\\"');

String _sanitizeComment(String s) =>
    s.replaceAll('{', '(').replaceAll('}', ')');

/// Numbered movetext for [solutionSan] starting from [fen]
/// (e.g. `4... Qh4# 5. Ke2`), with an optional leading brace [comment].
String buildMovetext(
  String fen,
  List<String> solutionSan, {
  String? comment,
  String result = '*',
}) {
  final buf = StringBuffer();
  if (comment != null && comment.trim().isNotEmpty) {
    buf.write('{${_sanitizeComment(comment.trim())}} ');
  }
  if (solutionSan.isEmpty) {
    buf.write(result);
    return buf.toString();
  }

  final setup = Setup.parseFen(fen);
  var moveNum = setup.fullmoves;
  var isWhite = setup.turn == Side.white;

  for (int i = 0; i < solutionSan.length; i++) {
    if (isWhite) {
      buf.write('$moveNum. ');
    } else if (i == 0) {
      buf.write('$moveNum... ');
    }
    buf.write(solutionSan[i]);
    if (!isWhite) moveNum++;
    isWhite = !isWhite;
    buf.write(' ');
  }
  buf.write(result);
  return buf.toString();
}

/// One puzzle as a single PGN game.
///
/// [solutionSan] must already be SAN (see [TacticsEngine.lineToSan] for
/// converting a stored `correctLine` that may mix SAN and UCI).  When
/// [solutionSan] is empty but the puzzle has a `correctLine`, the raw tokens
/// are preserved in a `[CorrectLine]` header instead of the movetext.
String encodePuzzlePgn(
  TacticsPosition puzzle,
  List<String> solutionSan, {
  String? event,
  bool includeNote = true,
  List<String> solutionPvSan = const [],
}) {
  final headers = StringBuffer();
  void header(String tag, String value) {
    if (value.isNotEmpty) {
      headers.writeln('[$tag "${_escapeHeader(value)}"]');
    }
  }

  if (event != null) header('Event', event);
  headers.writeln('[White "${_escapeHeader(puzzle.gameWhite)}"]');
  headers.writeln('[Black "${_escapeHeader(puzzle.gameBlack)}"]');
  header('Date', puzzle.gameDate);
  header('Site', puzzle.gameUrl);
  headers.writeln('[Result "*"]');
  headers.writeln('[FEN "${puzzle.fen}"]');
  headers.writeln('[SetUp "1"]');

  // Mistake-mining provenance.
  header('GameId', puzzle.gameId);
  header('UserMove', puzzle.userMove);
  if (puzzle.mistakeType != TacticsSessionSettings.customMistakeType) {
    header('MistakeType', puzzle.mistakeType);
  }
  header('OpponentBestResponse', puzzle.opponentBestResponse);

  // Review stats.
  if (puzzle.reviewCount > 0) {
    header('ReviewCount', '${puzzle.reviewCount}');
    header('SuccessCount', '${puzzle.successCount}');
  }
  if (puzzle.lastReviewed != null) {
    header('LastReviewed', puzzle.lastReviewed!.toIso8601String());
  }
  if (puzzle.timeToSolve > 0) header('TimeToSolve', '${puzzle.timeToSolve}');
  if (puzzle.hintsUsed > 0) header('HintsUsed', '${puzzle.hintsUsed}');
  if (puzzle.rating > 0) header('StarRating', '${puzzle.rating}');

  // Longer display PV (the mainline is only the trainable line).
  if (solutionPvSan.isNotEmpty &&
      !_sameLine(solutionPvSan, solutionSan)) {
    header('SolutionPv', solutionPvSan.join(' '));
  }

  // Lossless fallback for lines that could not be converted to SAN.
  if (solutionSan.isEmpty && puzzle.correctLine.isNotEmpty) {
    header('CorrectLine', puzzle.correctLine.join('|'));
  }

  final movetext = buildMovetext(
    puzzle.fen,
    solutionSan,
    comment: includeNote ? puzzle.mistakeAnalysis : null,
  );
  return '$headers\n$movetext\n';
}

bool _sameLine(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// A whole set as a multi-game PGN.  Puzzles whose solution cannot be
/// converted to SAN are written with a `[CorrectLine]` header instead of
/// movetext (counted in `fallback`); puzzles whose FEN cannot be parsed at
/// all are unusable and dropped (counted in `dropped`).
({String pgn, int encoded, int fallback, int dropped}) encodePuzzlesToPgn(
  String setName,
  List<TacticsPosition> puzzles,
) {
  final engine = TacticsEngine();
  final games = <String>[];
  var fallback = 0;
  var dropped = 0;
  for (int i = 0; i < puzzles.length; i++) {
    final puzzle = puzzles[i];
    try {
      final san = engine.lineToSan(puzzle.fen, puzzle.correctLine);
      games.add(encodePuzzlePgn(
        puzzle,
        san,
        event: '$setName #${i + 1}',
        solutionPvSan: engine.lineToSan(puzzle.fen, puzzle.solutionPv),
      ));
      if (san.isEmpty && puzzle.correctLine.isNotEmpty) fallback++;
    } catch (_) {
      dropped++; // unparsable FEN — the trainer could not load it either
    }
  }
  return (
    pgn: games.join('\n'),
    encoded: games.length,
    fallback: fallback,
    dropped: dropped,
  );
}

/// Parse a puzzle-PGN (or any PGN of games with `[FEN]` headers) back into
/// [TacticsPosition]s.  Games with an unparsable mainline are skipped and
/// reported.  All custom headers are optional so third-party PGN imports
/// cleanly.
///
/// By default games without a `[FEN]` header are skipped — that guards the
/// import path against accidentally turning a whole game archive into
/// "puzzles".  Pass [requireFen] = false when the source is deliberate (a
/// study reviewed as flashcards): such games become play-the-mainline cards
/// from the standard starting position.
///
/// [onlyGame] restricts decoding to a single game index (reviewing one
/// chapter of a study).  [includeVariations] additionally expands every
/// variation into its own card starting at the branch point — the position
/// where the solver first has to find a move off the mainline.  Variation
/// cards are labeled "Variation N" in their context, carry no stats of
/// their own, and (having a mid-line FEN that matches no game's `[FEN]`
/// header) are ignored by [patchStatsInPgn] — their results are
/// session-only by design.
({List<TacticsPosition> puzzles, List<String> errors}) decodePuzzlesFromPgn(
  String content, {
  bool requireFen = true,
  bool includeVariations = false,
  int? onlyGame,
}) {
  final puzzles = <TacticsPosition>[];
  final errors = <String>[];
  final games = splitPgnIntoGames(stripBom(content));
  final seenFens = <String>{};

  for (int i = 0; i < games.length; i++) {
    if (onlyGame != null && i != onlyGame) continue;
    final gameText = games[i];
    final headers = extractHeaders(gameText);
    var fen = headers['FEN'];
    if (fen == null || fen.trim().isEmpty) {
      if (requireFen) {
        errors.add('Game ${i + 1}: no [FEN] header — skipped');
        continue;
      }
      fen = Chess.initial.fen;
    }

    try {
      final game = PgnGame.parsePgn(gameText);
      var pos = Chess.fromSetup(Setup.parseFen(fen)) as Position;
      final sanLine = <String>[];
      String? note = game.comments.isNotEmpty ? game.comments.join(' ') : null;

      for (final nodeData in game.moves.mainline()) {
        final move = pos.parseSan(nodeData.san);
        if (move == null) {
          throw FormatException('illegal move ${nodeData.san}');
        }
        // A comment on the first move also counts as the note.
        if (sanLine.isEmpty && note == null && nodeData.comments != null) {
          note = nodeData.comments!.join(' ');
        }
        sanLine.add(nodeData.san);
        pos = pos.play(move);
      }

      // Raw-token fallback written by the encoder for unconvertible lines.
      var correctLine = sanLine;
      if (correctLine.isEmpty) {
        correctLine = (headers['CorrectLine'] ?? '')
            .split('|')
            .where((s) => s.isNotEmpty)
            .toList();
      }
      if (correctLine.isEmpty) {
        errors.add('Game ${i + 1}: no moves — skipped');
        continue;
      }

      final setup = Setup.parseFen(fen);
      final side = setup.turn == Side.white ? 'White' : 'Black';
      puzzles.add(TacticsPosition(
        fen: fen,
        userMove: headers['UserMove'] ?? '',
        correctLine: correctLine,
        solutionPv: (headers['SolutionPv'] ?? '')
            .split(RegExp(r'\s+'))
            .where((s) => s.isNotEmpty)
            .toList(),
        mistakeType: headers['MistakeType'] ??
            TacticsSessionSettings.customMistakeType,
        mistakeAnalysis: note ?? '',
        positionContext: 'Move ${setup.fullmoves}, $side to play',
        gameWhite: _cleanName(headers['White']),
        gameBlack: _cleanName(headers['Black']),
        gameResult: headers['Result'] ?? '*',
        gameDate: headers['Date'] ?? '',
        gameId: headers['GameId'] ?? '',
        gameUrl: _cleanName(headers['Site']),
        opponentBestResponse: headers['OpponentBestResponse'] ?? '',
        reviewCount: int.tryParse(headers['ReviewCount'] ?? '') ?? 0,
        successCount: int.tryParse(headers['SuccessCount'] ?? '') ?? 0,
        lastReviewed: headers['LastReviewed'] != null
            ? DateTime.tryParse(headers['LastReviewed']!)
            : null,
        timeToSolve: double.tryParse(headers['TimeToSolve'] ?? '') ?? 0.0,
        hintsUsed: int.tryParse(headers['HintsUsed'] ?? '') ?? 0,
        rating: int.tryParse(headers['StarRating'] ?? '') ?? 0,
      ));
      seenFens.add(fen);

      if (includeVariations) {
        _expandVariations(
          game: game,
          gameNumber: i + 1,
          startFen: fen,
          headers: headers,
          puzzles: puzzles,
          errors: errors,
          seenFens: seenFens,
        );
      }
    } catch (e) {
      errors.add('Game ${i + 1}: $e — skipped');
    }
  }
  return (puzzles: puzzles, errors: errors);
}

/// One card per non-mainline root-to-leaf line of [game]'s move tree.
///
/// A card starts at the last position the solver shares with the mainline:
/// the position before the deviating ply (advanced past it when the
/// deviation is an *opponent* move, so the solver is always to move) — and
/// its line runs to the leaf.  Comments along the variation become the note.
void _expandVariations({
  required PgnGame<PgnNodeData> game,
  required int gameNumber,
  required String startFen,
  required Map<String, String> headers,
  required List<TacticsPosition> puzzles,
  required List<String> errors,
  required Set<String> seenFens,
}) {
  final startPos = Chess.fromSetup(Setup.parseFen(startFen)) as Position;
  final solverSide = startPos.turn;
  var varNum = 0;

  for (final line in _variationLines(game.moves)) {
    varNum++;
    try {
      var pos = startPos;
      String? cardFen;
      final tail = <String>[];
      final comments = <String>[];
      for (int t = 0; t < line.plies.length; t++) {
        final ply = line.plies[t];
        if (cardFen == null &&
            t >= line.deviation &&
            pos.turn == solverSide) {
          cardFen = pos.fen;
        }
        final move = pos.parseSan(ply.san);
        if (move == null) {
          throw FormatException('illegal move ${ply.san}');
        }
        if (t >= line.deviation && ply.comments != null) {
          comments.addAll(ply.comments!);
        }
        if (cardFen != null) tail.add(ply.san);
        pos = pos.play(move);
      }
      if (cardFen == null || tail.isEmpty) continue; // nothing to solve
      if (!seenFens.add(cardFen)) {
        errors.add('Game $gameNumber: variation $varNum starts at the same '
            'position as another card — skipped');
        continue;
      }

      final setup = Setup.parseFen(cardFen);
      final side = setup.turn == Side.white ? 'White' : 'Black';
      puzzles.add(TacticsPosition(
        fen: cardFen,
        userMove: '',
        correctLine: tail,
        mistakeType: TacticsSessionSettings.customMistakeType,
        mistakeAnalysis: comments.join(' '),
        positionContext:
            'Variation $varNum — Move ${setup.fullmoves}, $side to play',
        gameWhite: _cleanName(headers['White']),
        gameBlack: _cleanName(headers['Black']),
        gameResult: headers['Result'] ?? '*',
        gameDate: headers['Date'] ?? '',
        gameId: headers['GameId'] ?? '',
        gameUrl: _cleanName(headers['Site']),
      ));
    } catch (e) {
      errors.add('Game $gameNumber: variation $varNum: $e — skipped');
    }
  }
}

/// Every non-mainline root-to-leaf line in a PGN move tree, with the index
/// of its first ply off the mainline (the first non-first-child choice).
List<({List<PgnNodeData> plies, int deviation})> _variationLines(
    PgnNode<PgnNodeData> root) {
  final lines = <({List<PgnNodeData> plies, int deviation})>[];
  final prefix = <PgnNodeData>[];

  void walk(PgnNode<PgnNodeData> node, int deviation) {
    if (node.children.isEmpty) {
      if (deviation != -1) {
        lines.add((plies: List.of(prefix), deviation: deviation));
      }
      return;
    }
    for (int c = 0; c < node.children.length; c++) {
      final child = node.children[c];
      prefix.add(child.data);
      walk(child,
          deviation != -1 ? deviation : (c == 0 ? -1 : prefix.length - 1));
      prefix.removeLast();
    }
  }

  walk(root, -1);
  return lines;
}

String _cleanName(String? name) {
  if (name == null || name == '?') return '';
  return name;
}

/// The stat headers owned by the trainer (rewritten by [patchStatsInPgn]).
const _statTags = [
  'ReviewCount',
  'SuccessCount',
  'LastReviewed',
  'TimeToSolve',
  'HintsUsed',
  'StarRating',
];

/// Update *only* the review-stat headers inside an existing multi-game PGN,
/// leaving movetext, variations, comments, and all other headers untouched.
///
/// Used when an external PGN (e.g. a study) is reviewed as a puzzle set:
/// a full re-encode from [TacticsPosition]s would flatten variations and
/// drop annotations the tactics model cannot represent, so stats are patched
/// into the original text instead.  Games are matched to [puzzles] by their
/// `[FEN]` header; unmatched games pass through unchanged.
String patchStatsInPgn(String content, List<TacticsPosition> puzzles) {
  final stripped = stripBom(content);
  final games = splitPgnIntoGames(stripped);

  // Fidelity guard: splitPgnIntoGames splits on `[Event` lines and invents
  // headers for content that has none.  Only patch when the split is exact
  // (every game came from a real `[Event` line), otherwise leave the file
  // untouched — losing a stats write beats corrupting someone's PGN.
  final eventCount = RegExp(r'^\s*\[Event\b', multiLine: true)
      .allMatches(stripped)
      .length;
  if (games.isEmpty || eventCount != games.length) return content;

  final byFen = {for (final p in puzzles) p.fen: p};

  final patched = games.map((gameText) {
    // No [FEN] header = a chapter from the standard start (see
    // decodePuzzlesFromPgn with requireFen: false).
    final fen = extractHeaders(gameText)['FEN'] ?? Chess.initial.fen;
    final puzzle = byFen[fen];
    if (puzzle == null) return gameText;

    // Strip existing stat headers.
    final lines = gameText.split('\n').where((line) {
      final trimmed = line.trimLeft();
      return !_statTags.any((tag) => trimmed.startsWith('[$tag '));
    }).toList();

    // New stat headers (only the ones carrying information).
    final stats = <String>[
      if (puzzle.reviewCount > 0) '[ReviewCount "${puzzle.reviewCount}"]',
      if (puzzle.reviewCount > 0) '[SuccessCount "${puzzle.successCount}"]',
      if (puzzle.lastReviewed != null)
        '[LastReviewed "${puzzle.lastReviewed!.toIso8601String()}"]',
      if (puzzle.timeToSolve > 0) '[TimeToSolve "${puzzle.timeToSolve}"]',
      if (puzzle.hintsUsed > 0) '[HintsUsed "${puzzle.hintsUsed}"]',
      if (puzzle.rating > 0) '[StarRating "${puzzle.rating}"]',
    ];
    if (stats.isEmpty) return lines.join('\n');

    // Insert after the last header line.
    var lastHeader = -1;
    for (int i = 0; i < lines.length; i++) {
      if (lines[i].trimLeft().startsWith('[')) lastHeader = i;
      // Headers end at the first non-blank, non-header line (movetext).
      if (lines[i].trim().isNotEmpty && !lines[i].trimLeft().startsWith('[')) {
        break;
      }
    }
    lines.insertAll(lastHeader + 1, stats);
    return lines.join('\n');
  });

  return patched.join('\n\n');
}

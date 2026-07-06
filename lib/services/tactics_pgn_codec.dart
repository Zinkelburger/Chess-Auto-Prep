/// Puzzle set ↔ PGN interchange.
///
/// Each puzzle is one PGN "game": `[FEN]`/`[SetUp "1"]` headers, the solution
/// line as the mainline (first move = the solver's move), and the note as a
/// brace comment before the first move.  Human-readable, opens in any chess
/// GUI, and re-imports into a set.
///
/// Intentionally lossy: review stats, hints, and game ids are not carried
/// (CSV remains the lossless format).
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
/// converting a stored `correctLine` that may mix SAN and UCI).
String encodePuzzlePgn(
  TacticsPosition puzzle,
  List<String> solutionSan, {
  String? event,
  bool includeNote = true,
}) {
  final headers = StringBuffer();
  if (event != null) headers.writeln('[Event "${_escapeHeader(event)}"]');
  headers.writeln('[White "${_escapeHeader(puzzle.gameWhite)}"]');
  headers.writeln('[Black "${_escapeHeader(puzzle.gameBlack)}"]');
  if (puzzle.gameDate.isNotEmpty) {
    headers.writeln('[Date "${_escapeHeader(puzzle.gameDate)}"]');
  }
  headers.writeln('[Result "*"]');
  headers.writeln('[FEN "${puzzle.fen}"]');
  headers.writeln('[SetUp "1"]');

  final movetext = buildMovetext(
    puzzle.fen,
    solutionSan,
    comment: includeNote ? puzzle.mistakeAnalysis : null,
  );
  return '$headers\n$movetext\n';
}

/// A whole set as a multi-game PGN.  Puzzles whose solution cannot be
/// converted to SAN are skipped (reported in the returned record).
({String pgn, int encoded, int skipped}) encodePuzzlesToPgn(
  String setName,
  List<TacticsPosition> puzzles,
) {
  final engine = TacticsEngine();
  final games = <String>[];
  var skipped = 0;
  for (int i = 0; i < puzzles.length; i++) {
    final puzzle = puzzles[i];
    final san = engine.lineToSan(puzzle.fen, puzzle.correctLine);
    if (san.isEmpty && puzzle.correctLine.isNotEmpty) {
      skipped++;
      continue;
    }
    games.add(encodePuzzlePgn(
      puzzle,
      san,
      event: '$setName #${i + 1}',
    ));
  }
  return (pgn: games.join('\n'), encoded: games.length, skipped: skipped);
}

/// Parse a puzzle-PGN (or any PGN of games with `[FEN]` headers) back into
/// [TacticsPosition]s.  Games without a `[FEN]` header or with an unparsable
/// mainline are skipped and reported.
({List<TacticsPosition> puzzles, List<String> errors}) decodePuzzlesFromPgn(
  String content,
) {
  final puzzles = <TacticsPosition>[];
  final errors = <String>[];
  final games = splitPgnIntoGames(stripBom(content));

  for (int i = 0; i < games.length; i++) {
    final gameText = games[i];
    final headers = extractHeaders(gameText);
    final fen = headers['FEN'];
    if (fen == null || fen.trim().isEmpty) {
      errors.add('Game ${i + 1}: no [FEN] header — skipped');
      continue;
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

      if (sanLine.isEmpty) {
        errors.add('Game ${i + 1}: no moves — skipped');
        continue;
      }

      final setup = Setup.parseFen(fen);
      final side = setup.turn == Side.white ? 'White' : 'Black';
      puzzles.add(TacticsPosition(
        fen: fen,
        userMove: '',
        correctLine: sanLine,
        mistakeType: TacticsSessionSettings.customMistakeType,
        mistakeAnalysis: note ?? '',
        positionContext: 'Move ${setup.fullmoves}, $side to play',
        gameWhite: _cleanName(headers['White']),
        gameBlack: _cleanName(headers['Black']),
        gameResult: headers['Result'] ?? '*',
        gameDate: headers['Date'] ?? '',
        gameId: '',
      ));
    } catch (e) {
      errors.add('Game ${i + 1}: $e — skipped');
    }
  }
  return (puzzles: puzzles, errors: errors);
}

String _cleanName(String? name) {
  if (name == null || name == '?') return '';
  return name;
}

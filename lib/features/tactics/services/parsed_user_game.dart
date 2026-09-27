/// A PGN game parsed for the mining pass, with the user's side identified
/// and the flaw-tag context (clocks, time control, result) read off it.
library;

import 'package:chess_auto_prep/chess_core/pgn/pgn_parser.dart';
import 'package:dartchess/dartchess.dart';

import '../../../utils/clock_utils.dart';
import '../../../utils/movetext_builder.dart';

class ParsedUserGame {
  ParsedUserGame._({
    required this.game,
    required this.gameText,
    required this.userColor,
    required this.moves,
    required this.clocks,
    required this.baseTimeSeconds,
    required this.incrementSeconds,
    required this.userLost,
    required this.startPosition,
    required this.sourceMovetext,
  });

  /// [gameText] parsed, with the user's side identified, or null when
  /// neither PGN header names [username] (already lower-cased).
  ///
  /// Exact (case-insensitive) match only. A substring fallback can
  /// misattribute the user's side when an opponent's name is a superstring
  /// of the username (e.g. user "tal" vs opponent "talinda").
  ///
  /// Throws on unparseable PGN or a bad `[FEN]` header, like
  /// [parsePgnGame] and [Setup.parseFen] do.
  static ParsedUserGame? parse(String gameText, String username) {
    final game = parsePgnGame(gameText);
    final white = (game.headers['White'] ?? '').toLowerCase();
    final black = (game.headers['Black'] ?? '').toLowerCase();
    final Side userColor;
    if (white == username) {
      userColor = Side.white;
    } else if (black == username) {
      userColor = Side.black;
    } else {
      return null;
    }

    final moves = <String>[];
    final clocks = <double?>[];
    for (final node in game.moves.mainline()) {
      moves.add(node.san);
      clocks.add(clockSecondsFromComments(node.comments));
    }

    final (baseTime, increment) = parseTimeControl(game.headers['TimeControl']);
    final result = game.headers['Result'] ?? '*';
    final userLost =
        (result == '1-0' && userColor == Side.black) ||
        (result == '0-1' && userColor == Side.white);

    final setupFlag = game.headers['SetUp'] ?? game.headers['Setup'] ?? '';
    final fenHeader = game.headers['FEN'] ?? '';
    final startsFromStandard = !(setupFlag == '1' && fenHeader.isNotEmpty);
    return ParsedUserGame._(
      game: game,
      gameText: gameText,
      userColor: userColor,
      moves: moves,
      clocks: clocks,
      baseTimeSeconds: baseTime,
      incrementSeconds: increment,
      userLost: userLost,
      startPosition: startsFromStandard
          ? Chess.initial
          : Chess.fromSetup(Setup.parseFen(fenHeader)),
      // Capture the whole game once so every tactic mined from it can show
      // the full game in the analysis tab without re-fetching. Only for
      // standard starts — a numbered movetext replayed from move 1 would be
      // illegal for a game that began from a custom position (rare; those
      // fall back to solution-only display).
      sourceMovetext: startsFromStandard
          ? buildNumberedMovetext(
              moves,
              startMoveNumber: 1,
              whiteToMoveFirst: true,
            )
          : '',
    );
  }

  final PgnGame<PgnNodeData> game;
  final String gameText;
  final Side userColor;

  /// Mainline SAN, one entry per ply.
  final List<String> moves;

  /// Clock reading after each ply, from `[%clk]` comments; null where absent.
  final List<double?> clocks;

  /// Time control, for the tempo flaw tags.
  final int? baseTimeSeconds;
  final double? incrementSeconds;

  /// Whether the user lost, for the end-of-game `lucky` rule.
  final bool userLost;
  final Position startPosition;

  /// The whole game as numbered movetext, or empty for a custom start.
  final String sourceMovetext;

  bool get userIsWhite => userColor == Side.white;
  String get result => game.headers['Result'] ?? '*';
}

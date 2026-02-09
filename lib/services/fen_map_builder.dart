import 'package:dartchess_webok/dartchess_webok.dart';
import '../models/position_analysis.dart';

class FenMapBuilder {
  final Map<String, PositionStats> _stats = {};
  final Map<String, List<int>> _fenToGameIndices = {};

  FenMapBuilder();

  Future<void> processPgns(
    List<String> pgnList,
    String username,
    bool userIsWhite,
  ) async {
    final fullPgnText = pgnList.join('\n\n');
    final pgnGames = PgnGame.parseMultiGamePgn(fullPgnText);
    final usernameLower = username.toLowerCase();

    for (var i = 0; i < pgnGames.length; i++) {
      final game = pgnGames[i];
      _processGame(game, i, usernameLower, userIsWhite);
    }
  }

  void _processGame(
    PgnGame<PgnNodeData> game,
    int gameIndex,
    String usernameLower,
    bool userIsWhiteFilter,
  ) {
    final white = (game.headers['White'] ?? '').toLowerCase();
    final black = (game.headers['Black'] ?? '').toLowerCase();
    final result = game.headers['Result'] ?? '*';

    // Determine if the user is White or Black in this game
    bool isUserWhite = white.contains(usernameLower);
    bool isUserBlack = black.contains(usernameLower);
    
    // If strict color filtering is requested, skip games where user color doesn't match
    // Note: The AnalysisScreen passes userIsWhite as the *target* analysis color.
    // If we want to analyze White games, we should only process games where user was White.
    if (userIsWhiteFilter && !isUserWhite) return;
    if (!userIsWhiteFilter && !isUserBlack) return;
    
    // If user played neither (e.g. imported generic PGN), we might want to skip 
    // or treat as 'userIsWhiteFilter' perspective. 
    // For now, assuming we only analyze user's games.
    if (!isUserWhite && !isUserBlack) return;

    // Calculate result from user's perspective
    // 1.0 = Win, 0.0 = Loss, 0.5 = Draw
    double userResult;
    if (result.contains('1-0')) {
      userResult = isUserWhite ? 1.0 : 0.0;
    } else if (result.contains('0-1')) {
      userResult = isUserWhite ? 0.0 : 1.0;
    } else {
      userResult = 0.5;
    }

    // Traverse moves
    Position position = Chess.fromSetup(Setup.parseFen(game.headers['FEN'] ?? 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1'));
    
    // Add initial position? Usually we care about positions *after* moves.
    // But let's iterate moves.
    
    for (final nodeData in game.moves.mainline()) {
        final moveSan = nodeData.san;

        // Always link this game to the current position so the Games list
        // works for every position the user navigates to (tree / PGN).
        _linkGameToFen(position.fen, gameIndex);

        // Record win/loss/draw stats only for positions where it is the
        // user's turn (these drive the "Weak Positions" list).
        bool isUserTurn = (position.turn == Side.white && isUserWhite) || 
                          (position.turn == Side.black && isUserBlack);

        if (isUserTurn) {
             _updateStats(position.fen, userResult, gameIndex);
        }

        final move = position.parseSan(moveSan);
        if (move == null) break;
        position = position.play(move);
    }

    // Link the final position too (after the last move).
    _linkGameToFen(position.fen, gameIndex);
  }

  void _updateStats(String fen, double result, int gameIndex) {
      final normalizedFen = _normaliseFen(fen);

      if (!_stats.containsKey(normalizedFen)) {
          _stats[normalizedFen] = PositionStats(fen: normalizedFen);
      }

      final stats = _stats[normalizedFen]!;
      stats.games++;
      if (result == 1.0) {
        stats.wins++;
      } else if (result == 0.0) {
        stats.losses++;
      } else {
        stats.draws++;
      }

      // Also link for stats-only positions (covered by _linkGameToFen too,
      // but harmless to double-call because of the contains guard).
      _linkGameToFen(normalizedFen, gameIndex);
  }

  /// Index a game against a position so the Games list works for every FEN.
  void _linkGameToFen(String fen, int gameIndex) {
      final normalizedFen = _normaliseFen(fen);

      if (!_fenToGameIndices.containsKey(normalizedFen)) {
          _fenToGameIndices[normalizedFen] = [];
      }
      if (!_fenToGameIndices[normalizedFen]!.contains(gameIndex)) {
          _fenToGameIndices[normalizedFen]!.add(gameIndex);
      }
  }

  static String _normaliseFen(String fen) {
      final parts = fen.split(' ');
      return parts.length >= 4 ? parts.take(4).join(' ') : fen;
  }

  static Future<PositionAnalysis> fromFenMapBuilder(
    FenMapBuilder builder,
    List<String> pgnList,
  ) async {
    // Convert PGN list to GameInfo objects
    final games = pgnList.map((pgn) => GameInfo.fromPgn(pgn)).toList();

    return PositionAnalysis(
      positionStats: builder._stats,
      games: games,
      fenToGameIndices: builder._fenToGameIndices,
    );
  }
}


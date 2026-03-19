/// Shared DB-move selection helpers used by generation pipelines.
library;

import '../../models/explorer_response.dart';

/// Centralized thresholds so DB-only and engine-backed generation stay aligned.
const double kMinOurMovePlayRate = 1.0;
const double kMinOpponentPlayFraction = 0.01;

class OpponentReply {
  final String uci;
  final String san;
  final double probability;

  const OpponentReply({
    required this.uci,
    required this.san,
    required this.probability,
  });
}

class DbMoveFilters {
  static ExplorerMove? bestMoveForUs(
    ExplorerResponse? dbData, {
    required bool isWhiteRepertoire,
    double minPlayRate = kMinOurMovePlayRate,
  }) {
    return dbData?.bestMoveForSide(
      asWhite: isWhiteRepertoire,
      minPlayRate: minPlayRate,
    );
  }

  static List<OpponentReply> opponentReplies(
    ExplorerResponse? dbData, {
    double minPlayFraction = kMinOpponentPlayFraction,
  }) {
    if (dbData == null || dbData.moves.isEmpty) return const [];

    final replies = <OpponentReply>[];
    for (final move in dbData.moves) {
      if (move.uci.isEmpty) continue;
      final prob = move.playFraction;
      if (prob < minPlayFraction) continue;
      replies.add(
        OpponentReply(
          uci: move.uci,
          san: move.san,
          probability: prob,
        ),
      );
    }
    return replies;
  }
}

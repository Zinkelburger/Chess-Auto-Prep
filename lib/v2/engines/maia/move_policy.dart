import '../../chess/fen.dart';

/// How likely each legal move is at [fen] for a player rated [elo].
///
/// This is the opponent model the repertoire builder plans against: which
/// replies are common enough to need an answer, and which are rare enough to
/// leave alone. Asking never throws, because a position the model cannot
/// read is something the screen has to be able to say.
abstract interface class MovePolicy {
  Future<MaiaAnswer> policy(Fen fen, int elo);
}

sealed class MaiaAnswer {
  const MaiaAnswer();
}

/// Standard UCI → share, most likely first, legal moves only, summing to 1.
final class MaiaPolicy extends MaiaAnswer {
  const MaiaPolicy(this.shares);

  final Map<String, double> shares;
}

/// Plain English for the screen and the log: what could not be done.
final class MaiaFailed extends MaiaAnswer {
  const MaiaFailed(this.reason);

  final String reason;
}

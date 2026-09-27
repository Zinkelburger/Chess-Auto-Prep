import '../chess/fen.dart';
import 'engine.dart';

/// A finite move request. UCI clocks are milliseconds; depth and nodes are
/// independent limits. Numeric arguments prevent a custom binary's settings
/// from injecting commands into the protocol.
final class MoveBudget {
  const MoveBudget({
    this.milliseconds,
    this.depth,
    this.nodes,
    this.whiteTime,
    this.blackTime,
    this.increment = 0,
    this.movesToGo,
    this.deadline = const Duration(minutes: 10),
  });
  final int? milliseconds;
  final int? depth;
  final int? nodes;
  final int? whiteTime;
  final int? blackTime;
  final int increment;
  final int? movesToGo;
  final Duration deadline;

  String get command => [
    'go',
    if (milliseconds != null) 'movetime ${milliseconds!.clamp(1, 3600000)}',
    if (depth != null) 'depth ${depth!.clamp(1, 128)}',
    if (nodes != null) 'nodes ${nodes!.clamp(1, 1000000000000)}',
    if (whiteTime != null) 'wtime ${whiteTime!.clamp(1, 360000000)}',
    if (blackTime != null) 'btime ${blackTime!.clamp(1, 360000000)}',
    if (whiteTime != null) 'winc ${increment.clamp(0, 3600000)}',
    if (blackTime != null) 'binc ${increment.clamp(0, 3600000)}',
    if (movesToGo != null) 'movestogo ${movesToGo!.clamp(1, 1000)}',
    if (milliseconds == null &&
        depth == null &&
        nodes == null &&
        whiteTime == null)
      'depth 12',
  ].join(' ');
}

final class PlayingSearch {
  const PlayingSearch(this.analysis, this.bestMove);
  final Search analysis;

  /// Null means no move arrived before exit, failure or cancellation. A PV
  /// is never substituted for the engine's actual bestmove response.
  final Future<String?> bestMove;
}

abstract interface class PlayingEngine implements Engine {
  PlayingSearch play(Fen root, List<String> moves, MoveBudget budget);
}

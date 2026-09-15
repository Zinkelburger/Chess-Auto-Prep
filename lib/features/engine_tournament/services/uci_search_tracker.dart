/// Accumulates the `info` lines of one search in flight and turns the
/// closing `bestmove` into an [EngineSearch].
library;

import '../../../services/engine/uci_info_line.dart';
import 'uci_protocol.dart';

/// One `go` … `bestmove` exchange, from the arbiter's side of the pipe.
///
/// Only the principal variation counts: a MultiPV engine's lower lines would
/// otherwise overwrite the score of the move actually played. `info string`
/// is chatter whose words collide with real keys and is ignored outright.
class UciSearchTracker {
  UciSearchTracker({Stopwatch? clock}) : _clock = clock ?? Stopwatch() {
    _clock.start();
  }

  final Stopwatch _clock;

  int? _scoreCp;
  int? _scoreMate;
  int _depth = 0;
  int? _nodes;

  int? get scoreCp => _scoreCp;
  int? get scoreMate => _scoreMate;
  int get depth => _depth;
  int? get nodes => _nodes;

  /// Fold one `info …` line into the running state.
  void observeInfo(String line) {
    if (line.startsWith('info string')) return;
    final info = UciInfoLine.parse(line.replaceAll(RegExp(r'\s+'), ' '));
    if (info.multiPv != null && info.multiPv != 1) return;
    _depth = info.depth ?? _depth;
    _nodes = info.nodes ?? _nodes;
    if (info.scoreCp != null) {
      _scoreCp = info.scoreCp;
      _scoreMate = null;
    } else if (info.scoreMate != null) {
      _scoreMate = info.scoreMate;
      _scoreCp = null;
    }
  }

  /// Close the search with its `bestmove …` line.
  EngineSearch finish(String bestmoveLine) {
    _clock.stop();
    final parts = bestmoveLine.trim().split(RegExp(r'\s+'));
    final best = parts.length > 1 ? parts[1] : '';
    final ponderIndex = parts.indexOf('ponder');
    final ponder = ponderIndex >= 0 && ponderIndex + 1 < parts.length
        ? parts[ponderIndex + 1]
        : null;
    return EngineSearch(
      bestMoveUci: best,
      ponderUci: ponder,
      scoreCp: _scoreCp,
      scoreMate: _scoreMate,
      depth: _depth,
      nodes: _nodes,
      elapsedMs: _clock.elapsedMilliseconds,
    );
  }
}

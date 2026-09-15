/// Hivemind's dialect of UCI, read line by line.
///
/// It speaks UCI, but not the UCI a chess GUI expects: bughouse needs two
/// boards, so the dialect differs in three ways this file reads.
///
///   * `position fen <boardA>|<boardB>` — two crazyhouse FENs, pipe-separated.
///   * Moves carry a board digit: `1e2e4` is e2e4 on board A, `2d7d5` on B.
///   * `bestmove (d2d4,pass)` — a *joint* action, one half per board, where
///     `pass` (deliberately not moving) is a legal and often correct choice.
///
/// Pure functions of the text, so the exact lines a real engine prints can be
/// pinned in a test without a process behind them.
library;

import '../models/bughouse_state.dart';

/// What a `bestmove` line carries: the joint action, and the reply the engine
/// expects, when it printed one.
typedef BughouseBestMove = ({
  BughouseJointMove? best,
  BughouseJointMove? ponder,
});

/// Parsers for the lines Hivemind prints.
abstract final class BughouseEngineProtocol {
  /// `bestmove (d2d4,pass) ponder (d7d5,d2d4)`.
  static BughouseBestMove parseBestMove(String text) {
    const prefix = 'bestmove ';
    const ponderKey = ' ponder ';
    final ponderAt = text.indexOf(ponderKey);
    final bestPart = ponderAt >= 0
        ? text.substring(prefix.length, ponderAt)
        : text.substring(prefix.length);
    final ponderPart = ponderAt >= 0
        ? text.substring(ponderAt + ponderKey.length)
        : null;
    return (
      best: BughouseJointMove.tryParse(bestPart),
      ponder: ponderPart == null
          ? null
          : BughouseJointMove.tryParse(ponderPart),
    );
  }

  /// Whether [text] is a search `info` line worth parsing, as opposed to an
  /// `info string`.
  static bool isSearchInfo(String text) =>
      text.startsWith('info ') && text.contains(' depth ');

  /// One `info` line, or null when it carries nothing a reader can use.
  ///
  /// [hadTimeAdvantage] is stamped onto the line because it is most of what
  /// the raw score is made of — the network reads the `TimeAdvantage` bit as
  /// about ±0.58 of Q — and so decides which searches may be read against each
  /// other at all.
  static BughouseInfo? parseInfo(
    String text, {
    required bool hadTimeAdvantage,
  }) {
    final tokens = text.split(RegExp(r'\s+'));
    int depth = 0, nodes = 0, nps = 0, timeMs = 0, scoreCp = 0, multipv = 1;
    int? mateIn;
    final pv = <BughouseJointMove>[];

    for (var i = 0; i < tokens.length; i++) {
      switch (tokens[i]) {
        case 'depth':
          depth = int.tryParse(_at(tokens, i + 1)) ?? depth;
        case 'multipv':
          multipv = int.tryParse(_at(tokens, i + 1)) ?? multipv;
        case 'nodes':
          nodes = int.tryParse(_at(tokens, i + 1)) ?? nodes;
        case 'nps':
          nps = int.tryParse(_at(tokens, i + 1)) ?? nps;
        case 'time':
          timeMs = int.tryParse(_at(tokens, i + 1)) ?? timeMs;
        case 'score':
          // "score cp -230" or "score mate 3"
          switch (_at(tokens, i + 1)) {
            case 'cp':
              scoreCp = int.tryParse(_at(tokens, i + 2)) ?? scoreCp;
            case 'mate':
              mateIn = int.tryParse(_at(tokens, i + 2));
          }
        case 'pv':
          for (final token in tokens.sublist(i + 1)) {
            final move = BughouseJointMove.tryParse(token);
            if (move != null) pv.add(move);
          }
          i = tokens.length;
      }
    }
    if (depth == 0 && pv.isEmpty) return null;
    // The root's unvisited MCTS prior, Q = -1, which the engine prints as
    // `180*tan(-1.56)` = -16671 on the first line of every single search
    // before any node has been evaluated. Folded into the live eval it made
    // the headline number flash -164.41 and empty the bar at the start of
    // every pass. A node count, not the magic value, is what says "nothing has
    // actually been looked at yet".
    if (nodes <= 1) return null;
    return BughouseInfo(
      depth: depth,
      scoreCp: scoreCp,
      nodes: nodes,
      nps: nps,
      timeMs: timeMs,
      multipv: multipv,
      mateIn: mateIn,
      hadTimeAdvantage: hadTimeAdvantage,
      pv: pv,
    );
  }

  static String _at(List<String> tokens, int index) =>
      index >= 0 && index < tokens.length ? tokens[index] : '';

  /// The prefix of the line that names the inference backend.
  static const String backendPrefix = 'info string backend ';

  /// The backend and its readout out of the engine's own line:
  ///
  ///     info string backend ONNX Runtime (CPU) model hivemind.onnx batch 8
  ///     workers 4 intra-op threads 5
  ///
  /// [text] is the line without [backendPrefix]. The backend is everything up
  /// to ` model `; the detail is `4 workers · 5 threads · batch 8`, each part
  /// optional, so a build that stops reporting one of them shortens the
  /// readout rather than printing a zero.
  static ({String backend, String detail}) parseBackend(String text) {
    final modelAt = text.indexOf(' model ');
    final parts = <String>[
      if (_numberAfter(text, 'workers ') case final n?) '$n workers',
      if (_numberAfter(text, 'intra-op threads ') case final n?) '$n threads',
      if (_numberAfter(text, 'batch ') case final n?) 'batch $n',
    ];
    return (
      backend: modelAt > 0 ? text.substring(0, modelAt) : text,
      detail: parts.join(' · '),
    );
  }

  static final _leadingDigits = RegExp(r'^\d+');

  static int? _numberAfter(String text, String key) {
    final at = text.indexOf(key);
    if (at < 0) return null;
    final match = _leadingDigits.firstMatch(text.substring(at + key.length));
    return match == null ? null : int.tryParse(match[0]!);
  }
}

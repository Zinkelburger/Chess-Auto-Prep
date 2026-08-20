/// Raw engine continuations appended to exported lines.
///
/// A line stops where the build stopped — usually the ply cap — and that
/// leaves the reader mid-position with no idea what the game looks like a few
/// moves later. This walks each line's leaf with Stockfish at a deeper
/// setting than the build used and hands back a short principal variation to
/// tack on the end, marked in the PGN as the point where prepared theory
/// ends.
///
/// The tail is explicitly *not* repertoire. It carries no selection, no
/// expectimax, and no promise the opponent plays along; it is there so a
/// truncated line reads as a position rather than a cliff. Nothing downstream
/// treats these moves as prepared — they are appended after every metric has
/// been computed.
///
/// Work is keyed by leaf position, not by line: lines that end in the same
/// place (transpositions, shared tails) cost one search between them.
library;

import 'dart:async';

import '../../utils/chess_utils.dart' show playUciMove, uciToSan;
import '../../utils/fen_utils.dart' show isWhiteToMove;
import '../engine/stockfish_pool.dart';
import 'generation_config.dart';
import 'line_extractor.dart';

/// A computed continuation for one leaf position.
class EngineTail {
  const EngineTail({required this.movesSan, required this.depth});

  /// SAN moves to append, already legal from the leaf position.
  final List<String> movesSan;

  /// Depth the search actually reported.
  final int depth;
}

/// Computes tails for the leaf position of every line in [lines].
///
/// Returns a map keyed by leaf FEN. Lines with no leaf FEN, and positions
/// where the engine returns nothing, are simply absent — the caller appends
/// what it gets and leaves the rest alone.
///
/// [isCancelled] is polled between positions so a cancelled build stops
/// promptly; whatever was computed before the stop is still returned and is
/// still valid.
Future<Map<String, EngineTail>> computeEngineTails({
  required List<ExtractedLine> lines,
  required TreeBuildConfig config,
  required StockfishPool pool,
  bool Function()? isCancelled,
  Future<void> Function()? pauseGate,
  void Function(int done, int total)? onProgress,
}) async {
  final plies = config.engineTailPlies;
  if (plies <= 0) return const {};

  final fens = <String>{
    for (final line in lines)
      if (line.leafFen != null && line.leafFen!.isNotEmpty) line.leafFen!,
  };
  if (fens.isEmpty) return const {};

  final depth = config.resolvedEngineTailDepth;
  final targets = fens.toList();
  final out = <String, EngineTail>{};
  var done = 0;
  var next = 0;

  // One search per worker, in flight at once. The pool hands each
  // [discoverMoves] call its own worker, so running these serially would
  // leave every worker but one idle — on a 300-line export at the
  // verification depth that is the difference between a minute and twenty.
  Future<void> search() async {
    while (true) {
      if (isCancelled?.call() ?? false) return;
      if (pauseGate != null) await pauseGate();
      final index = next++;
      if (index >= targets.length) return;
      final fen = targets[index];

      final DiscoveryResult result;
      try {
        result = await pool.discoverMoves(
          fen: fen,
          depth: depth,
          multiPv: 1,
          isWhiteToMove: isWhiteToMove(fen),
        );
      } catch (_) {
        // A tail is a nicety; a failed search must never fail an export.
        continue;
      }
      onProgress?.call(++done, targets.length);
      if (result.lines.isEmpty) continue;

      final tail = _sanTail(fen, result.lines.first.pv, plies);
      if (tail.isEmpty) continue;
      // Single-threaded isolate: no lock needed around this write.
      out[fen] = EngineTail(movesSan: tail, depth: result.depth);
    }
  }

  final lanes = pool.workerCount < 1 ? 1 : pool.workerCount;
  await Future.wait([
    for (var i = 0; i < lanes && i < targets.length; i++) search(),
  ]);
  return out;
}

/// Convert the leading [plies] of a UCI principal variation to SAN, replaying
/// from [fen]. Stops at the first move that will not play — a PV can outrun
/// what the position allows once it is truncated.
List<String> _sanTail(String fen, List<String> pvUci, int plies) {
  final out = <String>[];
  var current = fen;
  for (final uci in pvUci) {
    if (out.length >= plies) break;
    final san = uciToSan(current, uci);
    if (san.isEmpty) break;
    final next = playUciMove(current, uci);
    if (next == null) break;
    out.add(san);
    current = next;
  }
  return out;
}

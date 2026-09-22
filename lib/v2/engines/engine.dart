import '../chess/fen.dart';
import 'engine_line.dart';

/// Something that analyses positions: Stockfish behind a pipe in the app,
/// a scripted engine in tests. Starting one is the supervisor's job.
abstract interface class Engine {
  String get name;

  /// Starts analysing [fen]; the previous search stops first. Scores in
  /// the lines are from the side to move, as UCI gives them.
  ///
  /// With [depth], the search runs to that depth and ends on its own, and
  /// a search asked for after it waits for it rather than stopping it: a
  /// fixed-depth verdict cut short is not the verdict that was asked for.
  Search analyse(Fen fen, {required int multiPv, int? depth});

  /// Completes when the process has gone, after [quit] or on its own, with
  /// why it went.
  Future<EngineExit> get exited;

  Future<void> quit();
}

/// How an engine's process ended, which is what decides whether starting
/// another one is worth anything.
enum EngineExit {
  /// It quit: because we asked it to, or because it fell over.
  ended,

  /// It stopped answering and was killed. Another engine may well work.
  unresponsive,
}

/// One search. [lines] ends when the search does, so a line from an
/// earlier search can never arrive on a later one.
final class Search {
  const Search({required this.lines, required this.stop});

  final Stream<EngineLine> lines;

  /// Asks the engine to stop; completes once it has.
  final Future<void> Function() stop;
}

/// The engine broke the protocol or went away while it was needed.
final class EngineFailure implements Exception {
  const EngineFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

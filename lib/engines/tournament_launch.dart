import '../chess/tournament/config.dart';
import 'engine_supervisor.dart';
import 'stockfish_install.dart';
import 'uci_process.dart';

/// Starts one tournament seat under [engines]: the binary [spec] names, or
/// the Stockfish [stockfish] installs when it names none. What the process
/// writes goes into [transcript]. The app and
/// `tools/run_engine_tournament.dart` both start their seats here.
Future<EngineStart> launchTournamentEngine(
  TournamentEngine spec,
  EngineTranscript transcript, {
  required StockfishInstall stockfish,
  required EngineSupervisor engines,
}) async {
  var path = spec.executable;
  if (path == null || path.isEmpty) {
    switch (await stockfish.locate()) {
      case StockfishMissing(:final reason):
        return StartFailed(reason);
      case StockfishReady(path: final installed):
        path = installed;
    }
  }
  return engines.start(
    path,
    options: spec.options,
    arguments: spec.arguments,
    transcript: transcript,
  );
}

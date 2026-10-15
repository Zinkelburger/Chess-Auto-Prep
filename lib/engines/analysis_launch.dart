import '../chess/tournament/config.dart';
import 'engine_supervisor.dart';

/// Whether [engine], one the user registered in Engine tournament, can run
/// the analysis: it names a program of its own. One without is the bundled
/// Stockfish under another name, which the analysis has already.
bool analysesBoard(TournamentEngine engine) =>
    (engine.executable ?? '').trim().isNotEmpty;

/// The options a registered engine analyses with: its own, with the
/// analysis's threads and table in place of the tournament's. Pondering is
/// a playing option and has no place here.
Map<String, String> analysisOptions(
  TournamentEngine engine, {
  required int cores,
  required int memoryMb,
}) => {
  for (final MapEntry(:key, :value) in engine.options.entries)
    if (!const {'Threads', 'Hash', 'Ponder'}.contains(key)) key: value,
  'Threads': '$cores',
  'Hash': '$memoryMb',
};

/// Starts [engine] under [engines] for the board's analysis. Options the
/// engine does not list are left out, so an engine without `Threads` or
/// `Hash` still starts.
Future<EngineStart> launchAnalysisEngine(
  TournamentEngine engine, {
  required EngineSupervisor engines,
  required int cores,
  required int memoryMb,
}) {
  final path = engine.executable?.trim() ?? '';
  if (path.isEmpty) {
    return Future.value(StartFailed('${engine.name} names no program.'));
  }
  return engines.start(
    path,
    options: analysisOptions(engine, cores: cores, memoryMb: memoryMb),
    arguments: engine.arguments,
    advertisedOnly: true,
  );
}

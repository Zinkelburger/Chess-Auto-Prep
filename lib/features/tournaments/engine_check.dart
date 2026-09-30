import '../../chess/fen.dart';
import '../../chess/tournament/config.dart';
import '../../engines/engine.dart';
import '../../engines/engine_supervisor.dart';
import '../../engines/playing_engine.dart';
import '../../engines/uci_process.dart' show EngineTranscript;
import 'game_runner.dart';

/// What testing an engine before it is registered came to.
sealed class EngineCheck {
  const EngineCheck();
}

final class EngineVerified extends EngineCheck {
  const EngineVerified(this.name, this.move);

  /// The engine's own `id name`.
  final String name;

  /// The legal move it played from the start position.
  final String move;
}

final class EngineRejected extends EngineCheck {
  const EngineRejected(this.reason, this.output);

  final String reason;

  /// The first lines the engine wrote, empty when it never ran.
  final List<String> output;
}

/// Starts [spec] through [launch] and asks it for one move from the start
/// position: the test an engine passes before it is registered, in the app
/// and in `tools/run_engine_tournament.dart --verify`. A rejection names
/// what went wrong and carries the first lines the engine wrote.
Future<EngineCheck> checkTournamentEngine(
  TournamentLauncher launch,
  TournamentEngine spec,
) async {
  if (spec.options.entries.any(
    (e) => '${e.key}${e.value}'.contains(RegExp(r'[\r\n]')),
  )) {
    return const EngineRejected('Engine options must be single lines.', []);
  }
  final transcript = EngineTranscript();
  final Engine engine;
  switch (await launch(spec, transcript)) {
    case StartFailed(:final reason):
      return EngineRejected(reason, transcript.lines);
    case Started(engine: final started):
      engine = started;
  }
  try {
    if (engine is! PlayingEngine) {
      return EngineRejected(
        '${engine.name} cannot play moves.',
        transcript.lines,
      );
    }
    final search = engine.play(
      Fen.initial,
      const [],
      const MoveBudget(depth: 1, deadline: _testDeadline),
    );
    final answers = await Future.wait<Object?>([
      search.bestMove,
      // A failed search ends its lines with an error; what went wrong is
      // read from the missing move and the engine's exit below.
      search.analysis.lines.drain<void>().catchError((Object _) {}),
    ]);
    final move = answers.first as String?;
    if (legalOpeningMove(move)) return EngineVerified(engine.name, move!);
    final exit = await engine.exited
        .then<EngineExit?>((exit) => exit)
        .timeout(const Duration(seconds: 1), onTimeout: () => null);
    return EngineRejected(switch ((move, exit)) {
      (final String move, _) => '${engine.name} played an illegal move: $move',
      (_, EngineExit.ended) => '${engine.name} crashed while searching',
      _ =>
        '${engine.name} sent no bestmove within ${_testDeadline.inSeconds} s',
    }, transcript.lines);
  } on Object catch (error) {
    return EngineRejected('Engine test failed: $error', transcript.lines);
  } finally {
    await engine.quit();
  }
}

const _testDeadline = Duration(seconds: 20);

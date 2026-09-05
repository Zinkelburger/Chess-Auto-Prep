@Tags(['engine'])
library;

/// The match runner against the real Hivemind.
///
/// Everything else about the runner is covered by a scripted fake, which is
/// what makes the rules testable at all. What a fake cannot check is the part
/// that only the real engine has an opinion about: whether a joint action it
/// actually returns replays onto the two boards, whether the `MultiPV`
/// shortlist a sampled ply asks for comes back with more than one line, and
/// whether a search budget of a hundred nodes is a search at all.
///
/// Skipped unless HIVEMIND_BIN and HIVEMIND_MODEL point at a build, exactly as
/// `bughouse_engine_test.dart` is, so CI without the engine stays green:
///
/// ```
/// HIVEMIND_BIN=~/.local/share/com.example.chess_auto_prep/bughouse/hivemind-linux \
/// HIVEMIND_MODEL=~/.local/share/com.example.chess_auto_prep/bughouse/hivemind.onnx \
/// HIVEMIND_LIB=~/.local/share/com.example.chess_auto_prep/bughouse \
///   scripts/ci.sh with -- flutter test --tags engine \
///     test/features/bughouse/bughouse_tournament_engine_test.dart
/// ```
import 'dart:io';

import 'package:chess_auto_prep/features/bughouse/models/bughouse_state.dart';
import 'package:chess_auto_prep/features/bughouse/models/bughouse_tournament.dart';
import 'package:chess_auto_prep/features/bughouse/services/bughouse_engine.dart';
import 'package:chess_auto_prep/features/bughouse/services/bughouse_tournament_runner.dart';
import 'package:chess_auto_prep/models/game_outcome.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dartchess/dartchess.dart';
import 'package:chess_auto_prep/features/bughouse/models/bughouse_rules.dart';

void main() {
  final bin = Platform.environment['HIVEMIND_BIN'];
  final model = Platform.environment['HIVEMIND_MODEL'];
  final libDir = Platform.environment['HIVEMIND_LIB'];
  final available = bin != null && model != null;

  group('a real match', () {
    late BughouseEngine engine;

    setUpAll(() async {
      if (!available) return;
      engine = await BughouseEngine.launch(
        executablePath: bin,
        modelPath: model,
        libraryPath: libDir,
      );
    });

    tearDownAll(() async {
      if (available) await engine.dispose();
    });

    test('engine and arbiter agree that the partner can rescue mate', () async {
      const fen =
          'rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR[] w KQkq - 1 3|rnbqkbnr/ppp1pppp/8/3P4/8/8/PPPP1PPP/RNBQKBNR[] b KQkq - 0 2';
      final position = BughouseState.tryParseDualFen(fen)!;
      expect(BughouseRules.losingBoard(position, Side.white), isNull);
      await engine.configure(team: Side.white, hasTimeAdvantage: false);
      await engine.setPosition(position);
      final search = await engine.search(nodes: 200);
      expect(search.best.toString(), '(pass,d8d5)');
      final saved = position.playMove(BughouseBoard.b, Move.parse('d8d5')!)!;
      expect(saved.boardA.isLegal(Move.parse('P@g3')!), isTrue);
    });

    test('plays a line out and the games replay', () async {
      // 1. d4 d5 2. Bf4 on board 1 — the opening this feature was built for.
      final start = BughouseState.initial();
      var opening = start;
      for (final san in ['d4', 'd5', 'Bf4']) {
        final move = opening.boardA.parseSan(san)!;
        opening = opening.playMove(BughouseBoard.a, move)!;
      }

      final config = BughouseTournamentConfig(
        name: 'd4 d5 Bf4',
        startDualFen: opening.dualFen,
        openingLabel: 'Board 1: d4 d5 Bf4',
        participants: const [
          BughouseParticipant(name: 'A + C', budget: BughouseBudget.nodes(100)),
          BughouseParticipant(name: 'B + D', budget: BughouseBudget.nodes(100)),
        ],
        games: 2,
        // Short: this is about the plumbing, not about the opening.
        maxPlies: 10,
        variety: const BughouseVariety(plies: 4, window: 0.05, lines: 3),
        seed: 11,
      );

      final games = await BughouseTournamentRunner(
        engine: engine,
        config: config,
      ).run();

      expect(games, hasLength(2));
      for (final game in games) {
        // The ply cap is what stops a ten-ply game, so anything else means the
        // engine stopped answering.
        expect(
          game.termination,
          anyOf(
            TerminationReason.maxMoves,
            TerminationReason.checkmate,
            TerminationReason.mutualSitting,
          ),
          reason: game.outcomeLabel,
        );
        expect(game.moves, isNotEmpty, reason: 'the engine moved');

        // Every recorded move replays: the run and the replay agree about the
        // cross-board piece flow, which is the one thing a stored game can
        // silently get wrong.
        final replayed = replayBughouseGame(opening, game.moves);
        expect(replayed.length, game.moves.length);
      }
      // Seats swapped for the second game, as configured.
      expect(games[0].whiteName, 'A + C');
      expect(games[1].whiteName, 'B + D');
    }, timeout: const Timeout(Duration(minutes: 5)));
  }, skip: available ? null : 'set HIVEMIND_BIN and HIVEMIND_MODEL');
}

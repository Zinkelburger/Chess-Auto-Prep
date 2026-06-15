/// Tactics end-to-end integration test.
///
/// This test hits the live Lichess API and depends on Stockfish being
/// available with execute permission. It is excluded from CI because it is
/// non-deterministic (network-dependent, timing-sensitive).
///
/// Run locally with:
///   flutter test integration_test/tactics_e2e_test.dart -d linux
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'helpers/tactics_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('Tactics — End-to-End', () {
    testWidgets(
      'import, start, show solution, play moves, complete tactic',
      (tester) async {
        await pumpApp(tester);

        await importAndWaitForPositions(tester);
        await tapStartSession(tester);
        expectTacticLoaded();

        final allMoves = await showSolutionAndParseMoves(tester);
        print('Solution moves: $allMoves');

        await playTacticMoves(tester, allMoves);
        await expectTacticCompleted(tester);
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });
}

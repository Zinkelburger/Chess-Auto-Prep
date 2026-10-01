import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/generation/legal_moves.dart';
import 'package:chess_auto_prep/chess/generation/played_policy.dart';
import 'package:chess_auto_prep/chess/generation/search_node.dart';
import 'package:chess_auto_prep/chess/generation/sources.dart';
import 'package:chess_auto_prep/chess/pgn/analysis_board.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/workspace/engine_analysis.dart';
import 'package:chess_auto_prep/workspace/engine_jobs.dart';
import 'package:chess_auto_prep/workspace/fill_gaps.dart';
import 'package:chess_auto_prep/workspace/fill_states.dart';
import 'package:chess_auto_prep/workspace/search_opponents.dart';
import 'package:dartchess/dartchess.dart' show Position, Side;
import 'package:flutter_test/flutter_test.dart';

import '../chess/generation/scripted_sources.dart';
import '../support/scripted_engine.dart';
import '../support/session_fixture.dart';

/// White king and pawn against a bare king: few moves, so a run is small.
const kingAndPawn = '4k3/8/8/8/8/8/4P3/4K3 w - - 0 1';

/// White may castle either way; Black to move in the mirror.
const castles = 'r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1';

/// A model that counts what it is asked and answers with [weights] as they
/// are, summing to whatever they sum to.
final class _Model implements OpponentPolicy {
  _Model(this.weights);

  final Map<String, double> weights;
  final asked = <String>[];

  @override
  Future<PolicyResult> policyFor(Position position) async {
    asked.add(position.fen);
    return PolicyFound(Policy(weights));
  }
}

double _sum(Iterable<double> shares) => shares.fold(0, (a, b) => a + b);

Map<String, double>? _shares(PolicyResult result, Position position) =>
    (result as PolicyFound).policy.sharesOver(
      legalMovesOf(position).map((move) => move.uci),
    );

/// Every opponent position under [node], with the shares of its replies.
Iterable<List<double>> _replyShares(SearchNode node) sync* {
  switch (node) {
    case OurNode(:final candidates):
      for (final c in candidates) {
        yield* _replyShares(c.child);
      }
    case OpponentNode(:final replies):
      yield [for (final r in replies) r.probability];
      for (final r in replies) {
        yield* _replyShares(r.child);
      }
    default:
  }
}

void main() {
  final afterE4 = afterUci(positionOf(kingAndPawn), 'e2e4');

  test('games become shares of one: an illegal move takes none, and the two '
      'spellings of castling are one move', () {
    final played = playedPolicy(afterE4, const [
      (uci: 'e8d8', games: 60),
      (uci: 'e8f7', games: 30),
      (uci: 'a1a1', games: 10),
    ]);
    expect(played.games, 90, reason: 'the illegal move is not a game here');
    final shares = played.policy.sharesOver(
      legalMovesOf(afterE4).map((move) => move.uci),
    )!;
    expect(shares['e8d8'], closeTo(2 / 3, 1e-12));
    expect(shares['e8f7'], closeTo(1 / 3, 1e-12));
    expect(_sum(shares.values), closeTo(1, 1e-12));

    final castling = playedPolicy(positionOf(castles), const [
      (uci: 'e1h1', games: 5),
      (uci: 'e1g1', games: 15),
      (uci: 'e1c1', games: 20),
    ]);
    expect(castling.games, 40);
    expect(castling.policy.weights, hasLength(2));
    expect(castling.policy.weights.values, containsAll([20.0, 20.0]));
  });

  group('a database as the opponent', () {
    PlayedAt table(Map<String, List<({String uci, int games})>> byFen) =>
        (fen) async => PlayedFound(byFen[fen.value] ?? const []);

    test('answers where it has the games, and leaves a position with fewer '
        'to Maia whole; either way the shares sum to one', () async {
      final afterE3 = afterUci(positionOf(kingAndPawn), 'e2e3');
      // A model whose weights sum to three, and one that sums to a fiftieth.
      for (final weights in [
        {'e8d8': 2.0, 'e8f7': 1.0},
        {'e8d8': 0.015, 'e8f7': 0.005},
      ]) {
        final model = _Model(weights);
        final opponent = DatabaseOpponent(
          name: 'Lichess masters',
          played: table({
            afterE4.fen: const [
              (uci: 'e8d8', games: 70),
              (uci: 'e8f7', games: 30),
            ],
            afterE3.fen: const [(uci: 'e8e7', games: 9)],
          }),
          fallback: model,
          fallbackUnder: 10,
        );
        final fromGames = _shares(await opponent.policyFor(afterE4), afterE4)!;
        expect(fromGames, {'e8d8': 0.7, 'e8f7': 0.3});
        expect(model.asked, isEmpty);
        final fromMaia = _shares(await opponent.policyFor(afterE3), afterE3)!;
        expect(model.asked, [afterE3.fen]);
        expect(fromMaia.keys, isNot(contains('e8e7')), reason: 'not blended');
        expect(
          fromMaia['e8d8'],
          closeTo(weights['e8d8']! / _sum(weights.values), 1e-12),
        );
        expect(_sum(fromMaia.values), closeTo(1, 1e-12));
      }
    });

    test('with no fallback answers from any game and stops where it has '
        'none; a database that cannot be asked stops it too', () async {
      final model = _Model({'e8d8': 1});
      final sparse = DatabaseOpponent(
        name: 'TWIC games',
        played: table({
          afterE4.fen: const [(uci: 'e8d8', games: 1)],
        }),
      );
      expect(_shares(await sparse.policyFor(afterE4), afterE4), {'e8d8': 1.0});
      final root = positionOf(kingAndPawn);
      expect(
        (await sparse.policyFor(root) as PolicyUnavailable).reason,
        'TWIC games has no games at this position',
      );
      final offline = DatabaseOpponent(
        name: 'Lichess masters',
        played: (_) async => const PlayedUnavailable('No connection.'),
        fallback: model,
        fallbackUnder: 10,
      );
      expect(
        (await offline.policyFor(afterE4) as PolicyUnavailable).reason,
        'No connection.',
      );
      expect(model.asked, isEmpty, reason: 'offline is not few games');
    });

    test('asks about a position once', () async {
      final asked = <Fen>[];
      final opponent = DatabaseOpponent(
        name: 'TWIC games',
        played: (fen) async {
          asked.add(fen);
          return const PlayedFound([(uci: 'e8d8', games: 3)]);
        },
      );
      await Future.wait([
        opponent.policyFor(afterE4),
        opponent.policyFor(afterE4),
      ]);
      expect(asked, hasLength(1));
    });
  });

  test('a search over a database with Maia behind it gives every opponent '
      'position replies that sum to one', () async {
    final fixture = await openSession('[Event "x"]\n[Result "*"]\n\n*\n');
    final analysis = EngineAnalysis(
      fixture.session,
      () async => Started(ScriptedEngine()),
    );
    addTearDown(fixture.dispose);
    addTearDown(analysis.dispose);
    await fixture.session.showAnalysisBoard(
      analysisBoard(side: Side.white, root: const Fen(kingAndPawn)),
    );
    final model = _Model({'e8d8': 2.0, 'e8f7': 1.0, 'e8e7': 0.5});
    final fill = FillGaps(
      session: fixture.session,
      jobs: EngineJobs(analysis),
      documents: fixture.store,
      tools: (_) async => FillReady(
        evaluator: ScriptedEvaluator(),
        policy: DatabaseOpponent(
          name: 'Lichess masters',
          played: (fen) async => PlayedFound(
            fen.value == afterE4.fen
                ? const [(uci: 'e8d8', games: 70), (uci: 'e8f7', games: 30)]
                : const [(uci: 'e8d8', games: 2)],
          ),
          fallback: model,
          fallbackUnder: 10,
        ),
        release: () async {},
      ),
    );
    addTearDown(fill.dispose);
    await fill.start(const FillRequest(elo: 2200, depthPlies: 4, rootMoves: 6));
    expect(fill.state, isA<FillDone>());
    final nodes = _replyShares(fill.found!.tree).toList();
    expect(nodes.length, greaterThan(2));
    expect(model.asked, isNotEmpty, reason: 'some positions fell to Maia');
    for (final shares in nodes) {
      expect(_sum(shares), closeTo(1, 1e-9));
      expect(shares.every((share) => share > 0 && share <= 1), isTrue);
    }
  });

  test('a database that cannot answer stops the run and says why in its own '
      'words; what was built is kept', () async {
    final fixture = await openSession('[Event "x"]\n[Result "*"]\n\n*\n');
    final analysis = EngineAnalysis(
      fixture.session,
      () async => Started(ScriptedEngine()),
    );
    addTearDown(fixture.dispose);
    addTearDown(analysis.dispose);
    await fixture.session.showAnalysisBoard(
      analysisBoard(side: Side.white, root: const Fen(kingAndPawn)),
    );
    final fill = FillGaps(
      session: fixture.session,
      jobs: EngineJobs(analysis),
      documents: fixture.store,
      tools: (_) async => FillReady(
        evaluator: ScriptedEvaluator(),
        policy: DatabaseOpponent(
          name: 'Lichess masters',
          played: (_) async =>
              const PlayedUnavailable('Lichess is rate-limiting requests.'),
        ),
        release: () async {},
      ),
    );
    addTearDown(fill.dispose);
    await fill.start(
      const FillRequest(elo: 2200, depthPlies: 3, replies: ReplySource.masters),
    );
    final done = fill.state as FillDone;
    expect(done.complete, isFalse);
    expect(done.stoppedBy, 'Lichess is rate-limiting requests.');
    expect(fill.found?.tree, isA<OurNode>(), reason: 'the first moves kept');
  });

  test('a request names its opponent so a saved search is never continued '
      'from another', () {
    const maia = FillRequest(elo: 2200);
    const masters = FillRequest(
      elo: 2200,
      replies: ReplySource.masters,
      fallbackUnder: 10,
    );
    const strict = FillRequest(elo: 2200, replies: ReplySource.masters);
    expect(maia.replyKey, 'maia');
    expect(masters.replyKey, 'masters+maia<10');
    expect(strict.replyKey, 'masters');
    expect(
      const FillRequest(elo: 2200, replies: ReplySource.lichess).replyKey,
      startsWith('lichess:Blitz,Rapid,Classical:'),
    );
    expect(maia.compatibleWith(masters), isFalse);
    expect(masters.compatibleWith(strict), isFalse);
    expect(
      const FillRequest(elo: 2200, fallbackUnder: 10).compatibleWith(maia),
      isTrue,
      reason: 'Maia has nothing to fall back to',
    );
  });
}

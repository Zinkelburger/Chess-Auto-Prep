/// The bughouse match arbiter.
///
/// Two things are worth pinning down here and are easy to get backwards, so
/// they get most of the tests: **who a mate belongs to** — a team is named by
/// the colour it holds on board 1 and holds the opposite on board 2, so a mate
/// over there flips the answer — and **what the sampler may pick**, since that
/// is what decides whether a ten-game match is ten games or one game ten
/// times, and it must never reach past the engine's own shortlist.
library;

import 'dart:math' as math;

import 'package:chess_auto_prep/features/bughouse/models/bughouse_state.dart';
import 'package:chess_auto_prep/features/bughouse/models/bughouse_tournament.dart';
import 'package:chess_auto_prep/features/bughouse/services/bughouse_engine.dart';
import 'package:chess_auto_prep/features/bughouse/services/bughouse_tournament_runner.dart';
import 'package:chess_auto_prep/models/game_outcome.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_bughouse_engine.dart';

BughouseTournamentConfig _config({
  int games = 1,
  bool alternateSeats = true,
  int maxPlies = 240,
  BughouseVariety variety = BughouseVariety.none,
  String? dualFen,
}) => BughouseTournamentConfig(
  name: 'Test match',
  startDualFen: dualFen ?? BughouseState.initial().dualFen,
  games: games,
  alternateSeats: alternateSeats,
  maxPlies: maxPlies,
  variety: variety,
  seed: 7,
);

/// One search answer whose only line is [best].
BughouseSearchResult _answer(String best) => scripted(best: best);

/// Fool's mate on board 1, as a sequence of joint actions.
///
/// The teams alternate, and only one of them is on move on board 1 at a time,
/// so each action touches one board. Board 2 is sat on throughout — a legal
/// choice, and the shortest way to keep the test about board 1.
const _foolsMateOnBoardA = [
  '(f2f3,pass)', // white team
  '(e7e5,pass)', // black team
  '(g2g4,pass)', // white team
  '(d8h4,pass)', // black team — mate
];

void main() {
  group('playing a game out', () {
    test('a mate on board 1 is a win for the team that gave it', () async {
      final engine = FakeBughouseEngine()
        ..script.addAll(_foolsMateOnBoardA.map(_answer));
      final runner = BughouseTournamentRunner(
        engine: engine,
        config: _config(),
      );

      final games = await runner.run();

      expect(games, hasLength(1));
      final game = games.single;
      expect(game.termination, TerminationReason.checkmate);
      expect(game.detail, 'board 1');
      // Black mated White on board 1, so the pair holding Black there won.
      expect(game.result, GameResult.blackWins);
      expect(game.plies, 4);
      expect(game.moves, ['1f2f3', '1e7e5', '1g2g4', '1d8h4']);
    });

    test('a mate on board 2 belongs to the other team', () async {
      // The same mate, transplanted to board 2. The seats cross over there, so
      // the *white* pair — which plays Black on board 2 — is the one giving it.
      final engine = FakeBughouseEngine()
        ..script.addAll([
          // Board 1 keeps ticking over so each team stays on move there; the
          // mate is built on board 2, where the white pair sits as Black.
          _answer('(a2a3,pass)'),
          _answer('(a7a6,f2f3)'), // black pair, White on board 2
          _answer('(b2b3,e7e5)'), // white pair, Black on board 2
          _answer('(b7b6,g2g4)'),
          _answer('(c2c3,d8h4)'), // mate on board 2
        ]);
      final runner = BughouseTournamentRunner(
        engine: engine,
        config: _config(),
      );

      final game = (await runner.run()).single;

      expect(game.termination, TerminationReason.checkmate);
      expect(game.detail, 'board 2');
      // Board 2's White was mated; that seat belongs to the pair holding Black
      // on board 1, so White on board 1 won.
      expect(game.result, GameResult.whiteWins);
    });

    test('a game nobody moves in is a draw by mutual sitting', () async {
      // The fake's default answer is "no move at all", which is what a team
      // that sits on every board it holds looks like from here.
      final runner = BughouseTournamentRunner(
        engine: FakeBughouseEngine(),
        config: _config(),
      );

      final game = (await runner.run()).single;

      expect(game.result, GameResult.draw);
      expect(game.termination, TerminationReason.mutualSitting);
      expect(game.plies, 0);
    });

    test('the ply limit ends a game as a draw', () async {
      // Four quiet knight moves, repeated: the game never ends on its own.
      final engine = FakeBughouseEngine();
      for (var i = 0; i < 20; i++) {
        engine.script.addAll([
          _answer('(g1f3,pass)'),
          _answer('(g8f6,pass)'),
          _answer('(f3g1,pass)'),
          _answer('(f6g8,pass)'),
        ]);
      }
      final runner = BughouseTournamentRunner(
        engine: engine,
        config: _config(maxPlies: 6),
      );

      final game = (await runner.run()).single;

      expect(game.result, GameResult.draw);
      expect(game.termination, TerminationReason.maxMoves);
      expect(game.plies, 6);
    });

    test('a half that will not play here is dropped, not fatal', () async {
      final engine = FakeBughouseEngine()
        ..script.addAll([
          _answer('(e2e4,pass)'),
          // `e7e9` is not a square, let alone a move. Its partner half is
          // legal and has to land anyway — an engine answer that is half
          // nonsense costs a tempo, not the game.
          _answer('(e7e9,e2e4)'),
        ]);
      final runner = BughouseTournamentRunner(
        engine: engine,
        config: _config(),
      );

      final game = (await runner.run()).single;

      expect(game.moves, ['1e2e4', '2e2e4']);
    });
  });

  group('the schedule', () {
    test('seats swap every other game, and can be pinned', () {
      final swapping = BughouseTournamentRunner(
        engine: FakeBughouseEngine(),
        config: _config(games: 4),
      );
      expect(swapping.seatsFor(0), (0, 1));
      expect(swapping.seatsFor(1), (1, 0));
      expect(swapping.seatsFor(2), (0, 1));

      final fixed = BughouseTournamentRunner(
        engine: FakeBughouseEngine(),
        config: _config(games: 4, alternateSeats: false),
      );
      expect(fixed.seatsFor(1), (0, 1));
    });

    test('every game is played, and each is recorded once', () async {
      final engine = FakeBughouseEngine();
      for (var i = 0; i < 3; i++) {
        engine.script.addAll(_foolsMateOnBoardA.map(_answer));
      }
      final finished = <int>[];
      final runner = BughouseTournamentRunner(
        engine: engine,
        config: _config(games: 3),
        onGameFinished: (game) => finished.add(game.number),
      );

      final games = await runner.run();

      expect(games.map((g) => g.number), [1, 2, 3]);
      expect(finished, [1, 2, 3]);
      // Seats swapped for game 2, so the names on the row swapped with them.
      expect(games[0].whiteName, 'Hivemind A');
      expect(games[1].whiteName, 'Hivemind B');
    });

    test('stopping ends the match after the game in flight', () async {
      final engine = FakeBughouseEngine();
      for (var i = 0; i < 3; i++) {
        engine.script.addAll(_foolsMateOnBoardA.map(_answer));
      }
      final runner = BughouseTournamentRunner(
        engine: engine,
        config: _config(games: 3),
        onGameFinished: (_) {},
      );
      // Stopping before the first search is answered is the same decision the
      // Stop button makes; it must not leave the match half-written.
      runner.stop();

      expect(await runner.run(), isEmpty);
      expect(runner.isStopped, isTrue);
    });
  });

  group('variety', () {
    // The shortlist the sampler is offered. Scores are the engine's raw ones,
    // and what matters is the gap between them in `q` — which is why they are
    // not evenly spaced in centipawns.
    BughouseSearchResult shortlist(List<(String, int)> lines) =>
        BughouseSearchResult(
          best: BughouseJointMove.tryParse(lines.first.$1),
          ponder: null,
          infos: [
            for (var i = 0; i < lines.length; i++)
              BughouseInfo(
                depth: 4,
                scoreCp: lines[i].$2,
                nodes: 500,
                nps: 100,
                timeMs: 1000,
                multipv: i + 1,
                pv: [BughouseJointMove.tryParse(lines[i].$1)!],
              ),
          ],
        );

    test('with variety off the engine\'s own choice is played', () {
      final picked = BughouseTournamentRunner.pickFromShortlist(
        shortlist([('(e2e4,pass)', 10), ('(d2d4,pass)', 5)]),
        BughouseVariety.none,
        math.Random(1),
      );
      // `none` still allows one candidate — rank 1 — so the answer is fixed.
      expect('$picked', '(e2e4,pass)');
    });

    test('a line outside the window is never picked', () {
      final search = shortlist([
        ('(e2e4,pass)', 10),
        ('(d2d4,pass)', 5),
        // Far below: 0.4 of q away, well outside a 0.05 window.
        ('(a2a3,pass)', -200),
      ]);
      const variety = BughouseVariety(plies: 8, window: 0.05, lines: 3);

      final seen = <String>{};
      for (var seed = 0; seed < 40; seed++) {
        seen.add(
          '${BughouseTournamentRunner.pickFromShortlist(search, variety, math.Random(seed))}',
        );
      }

      expect(seen, contains('(e2e4,pass)'));
      expect(seen, contains('(d2d4,pass)'));
      expect(seen, isNot(contains('(a2a3,pass)')));
    });

    test('a proven mate is never sampled around', () {
      final search = BughouseSearchResult(
        best: BughouseJointMove.tryParse('(d8h4,pass)'),
        ponder: null,
        infos: [
          BughouseInfo(
            depth: 4,
            scoreCp: 3000,
            mateIn: 1,
            nodes: 100,
            nps: 100,
            timeMs: 10,
            multipv: 1,
            pv: [BughouseJointMove.tryParse('(d8h4,pass)')!],
          ),
          BughouseInfo(
            depth: 4,
            scoreCp: 2990,
            nodes: 100,
            nps: 100,
            timeMs: 10,
            multipv: 2,
            pv: [BughouseJointMove.tryParse('(a7a6,pass)')!],
          ),
        ],
      );

      for (var seed = 0; seed < 10; seed++) {
        expect(
          '${BughouseTournamentRunner.pickFromShortlist(search, const BughouseVariety(), math.Random(seed))}',
          '(d8h4,pass)',
        );
      }
    });

    test(
      'sampling asks the engine for a shortlist, and only early on',
      () async {
        final engine = FakeBughouseEngine()
          ..script.addAll(_foolsMateOnBoardA.map(_answer));
        final runner = BughouseTournamentRunner(
          engine: engine,
          config: _config(
            variety: const BughouseVariety(plies: 2, window: 0.05, lines: 3),
          ),
        );

        await runner.run();

        // Two plies sampled with MultiPV 3, then back to a single line.
        expect(engine.configurations.map((c) => c.multiPv).take(4), [
          3,
          3,
          1,
          1,
        ]);
      },
    );
  });

  group('replay', () {
    test(
      'a stored game replays into the same positions it was played from',
      () async {
        final engine = FakeBughouseEngine()
          ..script.addAll(_foolsMateOnBoardA.map(_answer));
        final game = (await BughouseTournamentRunner(
          engine: engine,
          config: _config(),
        ).run()).single;

        final line = replayBughouseGame(BughouseState.initial(), game.moves);

        expect(line.length, 4);
        // Opens at the start, ready to be walked.
        expect(line.cursor, 0);
        expect(line.movetextFor(BughouseBoard.a), '1. f3 e5 2. g4 Qh4#');
        line.toEnd();
        expect(line.current.boardA.isCheckmate, isTrue);
      },
    );

    test('a capture crosses to the other board on replay too', () {
      // 1. e4 (A) d5 (A) exd5 (A) — the captured pawn is a *black* pawn, and
      // it lands in board 2's reserve, not board 1's. Getting this wrong is
      // the single easiest way to replay a different game from the one played.
      final line = replayBughouseGame(BughouseState.initial(), [
        '1e2e4',
        '1d7d5',
        '1e4d5',
      ]);
      line.toEnd();

      expect(line.current.boardA.pockets?.of(Side.black, Role.pawn), 0);
      expect(line.current.boardB.pockets?.of(Side.black, Role.pawn), 1);
    });

    test('a move that will not play stops the replay rather than throwing', () {
      final line = replayBughouseGame(BughouseState.initial(), [
        '1e2e4',
        '1e7e9',
        '1d2d4',
      ]);
      expect(line.length, 1);
    });
  });
}

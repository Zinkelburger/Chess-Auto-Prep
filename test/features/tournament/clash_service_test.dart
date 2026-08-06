/// The clash path, run for real against PGN fixtures.
///
/// This is the feature's core claim — "your repertoire has no answer to what
/// this opponent actually plays" — and until now nothing had executed it. The
/// engine flags are off (a clash run is about coverage gaps, not move
/// quality), so no Stockfish, Maia or Lichess call is made and the whole thing
/// runs headless.
///
/// Downloads are stubbed; everything downstream of them is the real
/// [RepertoireAuditService] walking a real [OpeningTree].
library;

import 'dart:io';

import 'package:chess_auto_prep/features/tournament/models/player_identity.dart';
import 'package:chess_auto_prep/features/tournament/models/roster_entry.dart';
import 'package:chess_auto_prep/features/tournament/services/clash_service.dart';
import 'package:chess_auto_prep/features/tournament/services/event_simulator.dart';
import 'package:chess_auto_prep/features/tournament/services/tournament_prep_service.dart';
import 'package:chess_auto_prep/models/analysis_player_info.dart';
import 'package:chess_auto_prep/models/opening_tree.dart';
import 'package:chess_auto_prep/services/analysis_games_service.dart';
import 'package:flutter_test/flutter_test.dart';

// ── Fixtures ────────────────────────────────────────────────────────────────

/// Our White repertoire: 1.e4 c5 2.Nf3 and then only the 2...d6 branch.
/// 2...Nc6 is deliberately uncovered — that is the hole under test.
const _whiteRepertoire = '''
[Event "White repertoire"]
[White "Me"]
[Black "Book"]
[Result "*"]

1. e4 c5 2. Nf3 d6 3. d4 cxd4 4. Nxd4 Nf6 5. Nc3 a6 *
''';

/// Our Black repertoire, for the colour-selection test.
const _blackRepertoire = '''
[Event "Black repertoire"]
[White "Book"]
[Black "Me"]
[Result "*"]

1. d4 Nf6 2. c4 e6 3. Nf3 d5 *
''';

/// One opponent game with [moves], with [opponent] on [asBlack ? 'Black' : 'White'].
String _game(String opponent, String moves, {bool asBlack = true}) =>
    '''
[Event "Rated game"]
[White "${asBlack ? 'someone_else' : opponent}"]
[Black "${asBlack ? opponent : 'someone_else'}"]
[Result "*"]

$moves *
''';

/// `target`'s archive: as Black they meet 1.e4 c5 2.Nf3 with Nc6 four times
/// out of six, which our White book cannot answer. The two games where they
/// hold White play a line our book would flag if it were counted — it must
/// not be, because those games say nothing about how they meet us.
String _opponentArchive(String username) => [
  _game(username, '1. e4 c5 2. Nf3 Nc6 3. Bb5 g6'),
  _game(username, '1. e4 c5 2. Nf3 Nc6 3. d4 cxd4'),
  _game(username, '1. e4 c5 2. Nf3 Nc6 3. Nc3 e5'),
  _game(username, '1. e4 c5 2. Nf3 Nc6 3. Bb5 e6'),
  _game(username, '1. e4 c5 2. Nf3 d6 3. d4 cxd4'),
  _game(username, '1. e4 c5 2. Nf3 d6 3. Bb5+ Bd7'),
  // Same player, other colour: 1.e4 as White, answered by ...e5.
  _game(username, '1. e4 e5 2. Nf3 Nc6 3. Bc4 Bc5', asBlack: false),
  _game(username, '1. e4 e5 2. Nf3 Nc6 3. Bb5 a6', asBlack: false),
].join('\n');

// ── Stubs ───────────────────────────────────────────────────────────────────

/// Serves a PGN from disk instead of the network.
class _CachedGames extends AnalysisGamesService {
  final String path;
  int findCalls = 0;

  _CachedGames(this.path);

  @override
  Future<AnalysisPlayerInfo?> findExistingPlayer(
    String platform,
    String username,
  ) async {
    findCalls++;
    return AnalysisPlayerInfo(platform: platform, username: username);
  }

  @override
  Future<String> analysisPgnPath(String platform, String username) async =>
      path;
}

/// Nothing cached: exercises the download-then-save branch.
class _DownloadingGames extends AnalysisGamesService {
  final String path;
  final String pgn;
  String? savedPgn;
  int downloads = 0;

  _DownloadingGames({required this.path, required this.pgn});

  @override
  Future<AnalysisPlayerInfo?> findExistingPlayer(String p, String u) async =>
      null;

  @override
  Future<String> downloadChesscomGames(
    String username, {
    int maxGames = 100,
    int? monthsBack,
    void Function(String)? onProgress,
  }) async {
    downloads++;
    onProgress?.call('stub download');
    return pgn;
  }

  @override
  Future<AnalysisPlayerInfo> saveAnalysisGames(
    String pgns, {
    required String platform,
    required String username,
    required int maxGames,
    int? monthsBack,
  }) async {
    savedPgn = pgns;
    return AnalysisPlayerInfo(platform: platform, username: username);
  }

  @override
  Future<String> analysisPgnPath(String p, String u) async => path;
}

/// Fetching always fails: the run must degrade, not throw.
class _FailingGames extends AnalysisGamesService {
  @override
  Future<AnalysisPlayerInfo?> findExistingPlayer(String p, String u) async =>
      null;

  @override
  Future<String> downloadChesscomGames(
    String username, {
    int maxGames = 100,
    int? monthsBack,
    void Function(String)? onProgress,
  }) async => throw const SocketException('network down');
}

// ── Helpers ─────────────────────────────────────────────────────────────────

late Directory tempDir;

Future<String> writeFixture(String name, String content) async {
  final file = File('${tempDir.path}/$name');
  await file.writeAsString(content);
  return file.path;
}

RosterEntry opponent(String id, String username, {String? name}) => RosterEntry(
  id: id,
  name: name ?? id,
  rating: 1900,
  identity: PlayerIdentity(
    chesscomUsername: username,
    confidence: IdentityConfidence.exact,
    source: IdentitySource.uscfOnlineEvent,
    evidence: 'test fixture',
  ),
);

Future<OpeningTree> repertoire(String pgn, {required bool isWhite}) async {
  final path = await writeFixture(
    'rep_${isWhite ? 'w' : 'b'}_${pgn.hashCode}.pgn',
    pgn,
  );
  return TournamentPrepService.buildRepertoireTree(
    pgnPaths: [path],
    isWhite: isWhite,
  );
}

const _config = ClashConfig(useStockfish: false, maxPly: 12);

void main() {
  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('clash_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  group('ClashService', () {
    test('finds the move our repertoire cannot answer', () async {
      final archive = await writeFixture(
        'target.pgn',
        _opponentArchive('target'),
      );
      final service = ClashService(games: _CachedGames(archive));

      final report = await service.run(
        opponent: opponent('t', 'target'),
        repertoire: await repertoire(_whiteRepertoire, isWhite: true),
        weAreWhite: true,
        config: _config,
      );

      expect(report.gaps, isNotEmpty, reason: report.warnings.join('; '));
      final nc6 = report.gaps.firstWhere((g) => g.missingMove == 'Nc6');

      expect(nc6.line, '1. e4 c5 2. Nf3'.replaceAll(RegExp(r'\d+\. '), ''));
      expect(nc6.gameCount, 4);
      expect(nc6.moveShare, closeTo(4 / 6, 0.01));
      expect(nc6.reachProbability, greaterThan(0));
      expect(nc6.weight, closeTo(nc6.reachProbability * nc6.moveShare, 1e-9));
      expect(report.username, 'target');
      expect(report.platform, 'chess.com');
      expect(report.weAreWhite, isTrue);
    });

    test(
      'ignores the opponent games where they held the other colour',
      () async {
        // In their games as White they answer 1.e4 with ...e5. Our book only
        // covers 1...c5, so if the colour filter leaked those games in, `e5`
        // would surface as an uncovered response — prep built on evidence that
        // says nothing about how this player meets us.
        final archive = await writeFixture(
          'target.pgn',
          _opponentArchive('target'),
        );
        final report = await ClashService(games: _CachedGames(archive)).run(
          opponent: opponent('t', 'target'),
          repertoire: await repertoire(_whiteRepertoire, isWhite: true),
          weAreWhite: true,
          config: _config,
        );

        expect(
          report.gaps.map((g) => g.missingMove),
          isNot(contains('e5')),
          reason:
              'their games as White are not evidence about how they meet us',
        );
        // And the gap we do find is scaled by their Black games only: 4 of 6,
        // not 4 of 8.
        final nc6 = report.gaps.firstWhere((g) => g.missingMove == 'Nc6');
        expect(nc6.moveShare, closeTo(4 / 6, 0.01));
      },
    );

    test('does not report a move the repertoire already covers', () async {
      final archive = await writeFixture(
        'target.pgn',
        _opponentArchive('target'),
      );
      final report = await ClashService(games: _CachedGames(archive)).run(
        opponent: opponent('t', 'target'),
        repertoire: await repertoire(_whiteRepertoire, isWhite: true),
        weAreWhite: true,
        config: _config,
      );

      // 2...d6 is in our book, so it is coverage, not a gap.
      expect(report.gaps.map((g) => g.missingMove), isNot(contains('d6')));
    });

    test('gaps are ranked by weight', () async {
      final archive = await writeFixture(
        'target.pgn',
        _opponentArchive('target'),
      );
      final report = await ClashService(games: _CachedGames(archive)).run(
        opponent: opponent('t', 'target'),
        repertoire: await repertoire(_whiteRepertoire, isWhite: true),
        weAreWhite: true,
        config: _config,
      );

      final weights = report.gaps.map((g) => g.weight).toList();
      expect(
        weights,
        orderedEquals(([...weights]..sort((a, b) => b.compareTo(a)))),
      );
    });

    test('minMoveShare filters out one-off experiments', () async {
      final archive = await writeFixture(
        'target.pgn',
        _opponentArchive('target'),
      );
      final report = await ClashService(games: _CachedGames(archive)).run(
        opponent: opponent('t', 'target'),
        repertoire: await repertoire(_whiteRepertoire, isWhite: true),
        weAreWhite: true,
        // Nc6 is played 67% of the time, so a 90% floor must exclude it.
        config: const ClashConfig(useStockfish: false, minMoveShare: 0.9),
      );

      expect(report.gaps, isEmpty);
      expect(report.warnings.join(), contains('No uncovered moves'));
    });

    test('downloads when nothing is cached, and saves what it got', () async {
      final path = await writeFixture('dl.pgn', _opponentArchive('target'));
      final games = _DownloadingGames(
        path: path,
        pgn: _opponentArchive('target'),
      );

      final report = await ClashService(games: games).run(
        opponent: opponent('t', 'target'),
        repertoire: await repertoire(_whiteRepertoire, isWhite: true),
        weAreWhite: true,
        config: _config,
      );

      expect(games.downloads, 1);
      expect(games.savedPgn, isNotNull);
      expect(report.gaps, isNotEmpty);
    });

    test('a failed fetch degrades to a warning rather than throwing', () async {
      final report = await ClashService(games: _FailingGames()).run(
        opponent: opponent('t', 'target'),
        repertoire: await repertoire(_whiteRepertoire, isWhite: true),
        weAreWhite: true,
        config: _config,
      );

      expect(report.gaps, isEmpty);
      expect(report.warnings.join(), contains('Could not fetch games'));
    });

    test('an entrant with no account is reported, not attempted', () async {
      final report = await ClashService(games: _FailingGames()).run(
        opponent: const RosterEntry(id: 'x', name: 'Unknown', rating: 1800),
        repertoire: await repertoire(_whiteRepertoire, isWhite: true),
        weAreWhite: true,
        config: _config,
      );

      expect(report.username, isEmpty);
      expect(report.warnings.join(), contains('No online account resolved'));
    });

    test('reports progress while it works', () async {
      final archive = await writeFixture(
        'target.pgn',
        _opponentArchive('target'),
      );
      final stages = <String>[];

      await ClashService(games: _CachedGames(archive)).run(
        opponent: opponent('t', 'target'),
        repertoire: await repertoire(_whiteRepertoire, isWhite: true),
        weAreWhite: true,
        config: _config,
        onProgress: (p) => stages.add(p.stage),
      );

      expect(stages, contains('games'));
      expect(stages, contains('clash'));
    });

    test('serializes to JSON for the MCP wire', () async {
      final archive = await writeFixture(
        'target.pgn',
        _opponentArchive('target'),
      );
      final report = await ClashService(games: _CachedGames(archive)).run(
        opponent: opponent('t', 'target', name: 'Target Player'),
        repertoire: await repertoire(_whiteRepertoire, isWhite: true),
        weAreWhite: true,
        config: _config,
      );

      final map = report.toMap();
      expect(map['player_name'], 'Target Player');
      expect(map['we_are_white'], isTrue);
      expect((map['gaps'] as List), isNotEmpty);
      final gap = (map['gaps'] as List).first as Map<String, dynamic>;
      expect(gap['missing_move'], isA<String>());
      expect(gap['weight'], isA<num>());
    });
  });

  group('TournamentPrepService', () {
    test('pools a shared gap across opponents and ranks by total', () async {
      // A field big enough that we meet several of them with White — in a
      // three-player event the colours barely mix, so only one entrant would
      // ever reach the White book and there would be nothing to pool.
      final archive = await writeFixture(
        'shared.pgn',
        _opponentArchive('target'),
      );
      final prep = TournamentPrepService(
        clash: ClashService(games: _CachedGames(archive)),
      );

      final roster = Roster(
        eventName: 'Fixture Open',
        rounds: 3,
        entries: [
          const RosterEntry(id: 'me', name: 'Me', rating: 1900, isMe: true),
          for (var i = 0; i < 7; i++)
            opponent(
              'p$i',
              'target',
              name: 'Player $i',
            ).copyWith(rating: 1950 - i * 25),
        ],
      );

      final report = await prep.prepareEvent(
        roster: roster,
        whiteRepertoire: await repertoire(_whiteRepertoire, isWhite: true),
        blackRepertoire: null,
        clashConfig: _config,
        simConfig: const SimulationConfig(trials: 200),
      );

      expect(report.positions, isNotEmpty, reason: report.warnings.join('; '));
      final nc6 = report.positions.firstWhere((p) => p.missingMove == 'Nc6');

      // Everyone shares the archive, so the one position must carry several
      // entrants rather than appearing once per player.
      expect(
        nc6.opponentCount,
        greaterThan(1),
        reason: 'a shared gap should pool, not duplicate',
      );
      expect(
        report.positions.where((p) => p.missingMove == 'Nc6'),
        hasLength(1),
        reason: 'the same FEN + move is one thing to study',
      );

      // The score is exactly the sum of its parts.
      expect(
        nc6.score,
        closeTo(
          nc6.opponents.fold<double>(0, (s, o) => s + o.contribution),
          1e-9,
        ),
      );
      // Each contribution is P(face with White) × P(reach) × P(they play it).
      for (final o in nc6.opponents) {
        expect(
          o.contribution,
          closeTo(o.pairingProb * o.reachProbability * o.moveShare, 1e-9),
        );
      }

      // Ranked descending, and its own opponents ranked descending too.
      final scores = report.positions.map((p) => p.score).toList();
      expect(
        scores,
        orderedEquals(([...scores]..sort((a, b) => b.compareTo(a)))),
      );
      final contributions = nc6.opponents.map((o) => o.contribution).toList();
      expect(
        contributions,
        orderedEquals(([...contributions]..sort((a, b) => b.compareTo(a)))),
      );
    });

    test('skips opponents below the pairing threshold', () async {
      final archive = await writeFixture(
        'shared.pgn',
        _opponentArchive('target'),
      );
      final games = _CachedGames(archive);
      final prep = TournamentPrepService(clash: ClashService(games: games));

      final roster = Roster(
        rounds: 1,
        entries: [
          const RosterEntry(id: 'me', name: 'Me', rating: 1900, isMe: true),
          opponent('a', 'target', name: 'A'),
          // Far enough down the field that a 1-round event never pairs us.
          opponent('z', 'target', name: 'Z').copyWith(rating: 800),
        ],
      );

      final report = await prep.prepareEvent(
        roster: roster,
        whiteRepertoire: await repertoire(_whiteRepertoire, isWhite: true),
        blackRepertoire: null,
        clashConfig: _config,
        simConfig: const SimulationConfig(trials: 100),
        minPairingProb: 0.5,
      );

      final clashed = report.clashReports.map((c) => c.playerId).toSet();
      expect(clashed, isNot(contains('z')));
    });

    test(
      'reports entrants it could not clash for want of an account',
      () async {
        final archive = await writeFixture(
          'shared.pgn',
          _opponentArchive('target'),
        );
        final prep = TournamentPrepService(
          clash: ClashService(games: _CachedGames(archive)),
        );

        final roster = Roster(
          rounds: 1,
          entries: [
            const RosterEntry(id: 'me', name: 'Me', rating: 1900, isMe: true),
            const RosterEntry(id: 'nobody', name: 'No Account', rating: 1890),
          ],
        );

        final report = await prep.prepareEvent(
          roster: roster,
          whiteRepertoire: await repertoire(_whiteRepertoire, isWhite: true),
          blackRepertoire: null,
          clashConfig: _config,
          simConfig: const SimulationConfig(trials: 100),
        );

        expect(report.positions, isEmpty);
        expect(report.warnings.join(), contains('no online account resolved'));
      },
    );

    test('says so plainly when there is no repertoire to clash', () async {
      final report = await TournamentPrepService().prepareEvent(
        roster: Roster(
          rounds: 1,
          entries: [
            const RosterEntry(id: 'me', name: 'Me', rating: 1900, isMe: true),
            opponent('a', 'target'),
          ],
        ),
        whiteRepertoire: null,
        blackRepertoire: null,
        simConfig: const SimulationConfig(trials: 50),
      );

      expect(report.positions, isEmpty);
      expect(report.warnings.join(), contains('No repertoire supplied'));
    });

    test('only clashes the colour that can actually occur', () async {
      // Black repertoire supplied but no White one: any gap found must come
      // from the Black book, and our White book must not be invented.
      final archive = await writeFixture(
        'shared.pgn',
        _opponentArchive('target'),
      );
      final prep = TournamentPrepService(
        clash: ClashService(games: _CachedGames(archive)),
      );

      final report = await prep.prepareEvent(
        roster: Roster(
          rounds: 3,
          entries: [
            const RosterEntry(id: 'me', name: 'Me', rating: 1900, isMe: true),
            opponent('a', 'target'),
          ],
        ),
        whiteRepertoire: null,
        blackRepertoire: await repertoire(_blackRepertoire, isWhite: false),
        clashConfig: _config,
        simConfig: const SimulationConfig(trials: 200),
      );

      for (final position in report.positions) {
        expect(position.weAreWhite, isFalse);
      }
      for (final clash in report.clashReports) {
        expect(clash.weAreWhite, isFalse);
      }
    });

    test('the report renders to PGN and a briefing', () async {
      final archive = await writeFixture(
        'shared.pgn',
        _opponentArchive('target'),
      );
      final prep = TournamentPrepService(
        clash: ClashService(games: _CachedGames(archive)),
      );

      final report = await prep.prepareEvent(
        roster: Roster(
          eventName: 'Fixture Open',
          rounds: 3,
          entries: [
            const RosterEntry(id: 'me', name: 'Me', rating: 1900, isMe: true),
            opponent('a', 'target', name: 'Player A'),
          ],
        ),
        whiteRepertoire: await repertoire(_whiteRepertoire, isWhite: true),
        blackRepertoire: null,
        clashConfig: _config,
        simConfig: const SimulationConfig(trials: 200),
      );

      expect(report.positions, isNotEmpty);
      expect(report.toMap()['positions'], isNotEmpty);
      expect(report.topByCoverage(0.8), isNotEmpty);
    });
  });
}

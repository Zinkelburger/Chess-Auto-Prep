/// [CourseBuilder] on its own — the half of an export that turns extracted
/// lines into a course document.
///
/// The branching worth pinning is the model-game source ladder and the note
/// that explains an empty result. It used to live on
/// `GenerationSessionController` as a private method that assigned to a
/// public field, so testing it meant standing up a whole build; here it is a
/// value the builder returns.
library;

import 'package:dartchess/dartchess.dart';
import 'package:chess_auto_prep/chess_core/generation/build_tree_node.dart';
import 'package:chess_auto_prep/chess_core/position/eval_canonicalize.dart';
import 'package:chess_auto_prep/models/analysis/discovery_result.dart';
import 'package:chess_auto_prep/services/maia/maia_factory.dart';
import 'package:chess_auto_prep/services/master_games/master_games_db.dart';

import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/services/generation/course/course_builder.dart';
import 'package:chess_auto_prep/services/generation/export/move_annotation.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/generation/line_extractor.dart';
import 'package:chess_auto_prep/services/generation/pgn_freq_map.dart';
import 'package:flutter_test/flutter_test.dart';

import '../generation_test_helpers.dart';
import '../engine_fakes.dart';

ExtractedLine _line(List<String> san) => ExtractedLine(
  movesSan: san,
  movesUci: san,
  probability: 0.2,
  moveAnnotations: [
    for (var i = 0; i < san.length; i++) const MoveAnnotation(),
  ],
);

/// An engine build: no game database is involved, so "no database" is not
/// something the user needs to hear about.
TreeBuildConfig _engineBuild({int modelGames = 3}) => TreeBuildConfig(
  startFen: kStandardStartFen,
  playAsWhite: true,
  buildMode: BuildMode.stockfishExpectimax,
  modelGameCount: modelGames,
  refutationLines: false,
  alternativeLines: false,
  engineTailPlies: 0,
);

/// A database build: the user asked for games, so an empty result is worth
/// explaining.
TreeBuildConfig _databaseBuild({int modelGames = 3}) => TreeBuildConfig(
  startFen: kStandardStartFen,
  playAsWhite: true,
  buildMode: BuildMode.dbExplorer,
  modelGameCount: modelGames,
  refutationLines: false,
  alternativeLines: false,
  engineTailPlies: 0,
);

/// A game that shares no position with the fixture repertoire, so it is a
/// candidate the selector will look at and reject.
const _unrelatedGame = PgnGameRecord(
  white: 'Petrosian',
  black: 'Spassky',
  whiteElo: 2650,
  blackElo: 2690,
  event: 'Moscow',
  date: '1966.04.11',
  outcome: GameOutcome.draw,
  movesSan: ['b3', 'e5', 'Bb2', 'Nc6'],
);

PgnFreqMap _databaseHolding(PgnGameRecord game) =>
    PgnFreqMap()..games.offer(game);

// Startup is scripted too: the production pool must never launch a process.
class _Pool extends FakeStockfishPool {
  _Pool() : super(workers: 0);
  final budgets = <int>[];
  bool failFirstWarmup = false;

  @override
  Future<void> prepareForTreeBuild(int threadBudget) async {
    budgets.add(threadBudget);
    if (failFirstWarmup && budgets.length == 1) {
      throw StateError('engine startup failed');
    }
    workers = 1;
  }
}

String _fen(List<String> sans) {
  Position position = Chess.initial;
  for (final san in sans) {
    position = position.play(position.parseSan(san)!);
  }
  return position.fen;
}

ExtractedLine _probeLine(
  List<String> sans, {
  bool punish = false,
  List<LineChoice> choices = const [],
}) {
  Position position = Chess.initial;
  final ucis = <String>[];
  for (final san in sans) {
    final move = position.parseSan(san)!;
    ucis.add(move.uci);
    position = position.play(move);
  }
  return ExtractedLine(
    movesSan: sans,
    movesUci: ucis,
    probability: 0.2,
    leafFen: position.fen,
    choices: choices,
    leafPruneReason: punish ? PruneReason.evalTooHigh : PruneReason.none,
    moveAnnotations: [for (final _ in sans) const MoveAnnotation()],
  );
}

DiscoveryResult _result(List<String> pv, {int cp = 320}) => DiscoveryResult(
  lines: [discoveryLine(pvNumber: 1, cpWhite: cp, pv: pv)],
  depth: 14,
);

final _blunder = _probeLine(
  ['e4', 'e5', 'Nc3', 'Nf6', 'Bc4', 'Nxe4'],
  punish: true,
  choices: [
    const LineChoice(
      moveIndex: 0,
      fenBefore: kStandardStartFen,
      isOurMove: true,
      bestEvalCpForUs: 30,
      knownUcis: ['e2e4'],
    ),
  ],
);
final _italian = _probeLine(
  ['e4', 'e5', 'Nf3', 'Nc6', 'Bc4'],
  choices: [
    LineChoice(
      moveIndex: 4,
      fenBefore: _fen(['e4', 'e5', 'Nf3', 'Nc6']),
      isOurMove: true,
      bestEvalCpForUs: 60,
      knownUcis: const ['f1c4'],
    ),
  ],
);

// Only the existing database read boundary is faked; the improvement prober
// still chooses, evaluates, replays, and cites the supplied game itself.
class _MasterDb implements MasterGamesDb {
  @override
  List<BookMove> bookMoves(String fen) =>
      fen == _italian.choices.single.fenBefore
      ? [
          const BookMove(
            uci: 'f1b5',
            games: 40,
            whiteWins: 20,
            draws: 20,
            blackWins: 0,
            averageElo: 2600,
            maxElo: 2800,
            lastYear: 2025,
            topGameId: 1,
            recentGameId: 1,
          ),
        ]
      : [];
  @override
  MasterGame? game(int id) => id == 1
      ? const MasterGame(
          id: 1,
          twicIssue: 1600,
          event: 'Tata Steel',
          site: 'Wijk aan Zee',
          date: '2025.01.20',
          round: '3',
          white: 'Giri,A',
          black: 'Caruana,F',
          result: '1/2-1/2',
          whiteElo: 2740,
          blackElo: 2800,
          whiteFideId: null,
          blackFideId: null,
          eco: 'C65',
          plyCount: 8,
          movetext: '1. e4 e5 2. Nf3 Nc6 3. Bb5 Nf6 4. O-O Nxe4',
        )
      : null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StandardTree fixture;

  CourseBuilder makeBuilder({PgnFreqMap? database}) => CourseBuilder(
    pool: _Pool(),
    isCancelled: () => false,
    onStatus: (_) {},
    gameDatabase: () => database,
    // No master-games database in a unit test: the ladder's last rung is
    // what an ordinary machine without the TWIC download actually hits.
    masterDbFor: (_) => null,
    fenMap: () => null,
  );

  Future<CourseBuild> buildWith(
    TreeBuildConfig config, {
    PgnFreqMap? database,
  }) => makeBuilder(database: database).build(
    tree: fixture.toTree(),
    lines: [
      _line(['e4', 'e5', 'Nf3']),
      _line(['d4', 'd5', 'c4']),
    ],
    config: config,
    repertoireFilePath: '/tmp/Italian.pgn',
    rootFen: kStandardStartFen,
    prefix: const [],
  );

  setUp(() => fixture = StandardTree());

  group('the composed course', () {
    test('carries every line it was given', () async {
      final built = await buildWith(_engineBuild());
      expect(built.course.entries, isNotEmpty);
    });

    test('is named after the repertoire file, not its path', () async {
      final built = await buildWith(_engineBuild());
      expect(built.course.title, contains('Italian'));
    });
  });

  group('the model-game note', () {
    test('stays empty when model games were never asked for', () async {
      final built = await buildWith(_engineBuild(modelGames: 0));
      expect(built.modelGameNote, isEmpty);
      expect(built.course.modelGamePgns, isEmpty);
    });

    test(
      'stays empty on an engine build, which never has a database',
      () async {
        // The old code said "this build had no game database" here too, which
        // is noise: an engine build is not supposed to have one.
        final built = await buildWith(_engineBuild());
        expect(built.modelGameNote, isEmpty);
      },
    );

    test('explains the missing database on a build that wanted one', () async {
      final built = await buildWith(_databaseBuild());
      expect(built.modelGameNote, contains('no game database'));
    });

    test('names the database it searched when nothing in it fits', () async {
      // The database loaded and retained games — they just do not follow
      // this repertoire, which is a different thing from not having one and
      // the only one of the two the user can act on.
      final built = await buildWith(
        _databaseBuild(),
        database: _databaseHolding(_unrelatedGame),
      );
      expect(built.modelGameNote, contains('strongest games in the database'));
      expect(built.modelGameNote, contains('follows this repertoire'));
    });
  });

  group('enrichment through the actual course build', () {
    late _Pool pool;
    late List<String> statuses;
    late bool cancelled;
    PgnFreqMap? database;
    MasterGamesDb? master;
    final config = _databaseBuild(modelGames: 0).copyWith(
      refutationLines: true,
      alternativeLines: true,
      engineTailPlies: 2,
      engineThreads: 3,
      annotationDetail: MoveAnnotationDetail.full,
    );

    CourseBuilder builder({
      void Function(String)? status,
      PgnFreqMap? Function()? games,
    }) => CourseBuilder(
      pool: pool,
      isCancelled: () => cancelled,
      onStatus: status ?? statuses.add,
      gameDatabase: games ?? () => database,
      masterDbFor: (_) => master,
      fenMap: () => null,
    );

    Future<CourseBuild> build(
      CourseBuilder owner, {
      TreeBuildConfig? settings,
      List<ExtractedLine>? lines,
    }) => owner.build(
      tree: fixture.toTree(),
      lines: lines ?? [_blunder, _italian],
      config: settings ?? config,
      repertoireFilePath: '/tmp/Italian.pgn',
      rootFen: kStandardStartFen,
      prefix: const [],
    );

    setUp(() {
      pool = _Pool();
      statuses = [];
      cancelled = false;
      database = PgnFreqMap()
        ..recordMove(canonicalizeFen4(kStandardStartFen), 'f2f3', '');
      master = _MasterDb();
      MaiaFactory.testOverride = FakeMaiaEvaluator({});
      pool.discoveryByFen[_blunder.leafFen!] = _result([
        'c4f7',
        'e8e7',
        'c3e4',
      ]);
      pool.discoveryByFen[_fen(['f3'])] = _result([
        'e7e5',
        'g2g4',
        'd8h4',
      ], cp: -400);
      pool.discoveryByFen[_italian.leafFen!] = _result([
        'f8c5',
        'c2c3',
      ], cp: 60);
      pool.discoveryByFen[_fen(['e4', 'e5', 'Nf3', 'Nc6', 'Bb5'])] = _result([
        'a7a6',
      ], cp: 10);
    });
    tearDown(() => MaiaFactory.testOverride = null);

    test(
      'warms once with captured config and composes all findings in pass order',
      () async {
        final result = await build(builder());
        expect(pool.budgets, [3]);
        expect(result.enrichment, (
          refutations: 1,
          alternatives: 1,
          improvements: 1,
        ));
        expect(
          result.course.entries.expand((entry) => entry.refutation),
          contains('Bxf7+'),
        );
        expect(
          result.course.entries.expand((entry) => entry.refutedAlternatives),
          contains('f3'),
        );
        expect(result.course.toPgn(), contains('Bc4 improves on Bb5'));
        expect(
          result.course.entries
              .firstWhere((entry) => entry.movesSan[2] == 'Nf3')
              .movesSan,
          [..._italian.movesSan, 'Bc5', 'c3'],
        );
        final phases = statuses.map((s) => s.substring(0, 9)).toList();
        expect(phases.toSet().toList(), [
          'Phase 3.5',
          'Phase 3.6',
          'Phase 3.7',
          'Phase 3.8',
        ]);
        expect(statuses.first, contains('(1 of 1)'));
        expect(statuses.last, contains('(2 of 2 positions)'));
      },
    );

    for (final reason in [
      'disabled',
      'engine-free',
      'cancelled',
      'work-free',
    ]) {
      test('$reason does not warm or search the engine', () async {
        master = null;
        var settings = config.copyWith(engineTailPlies: 0);
        List<ExtractedLine>? lines;
        if (reason == 'disabled') {
          settings = settings.copyWith(
            refutationLines: false,
            alternativeLines: false,
          );
        } else if (reason == 'engine-free') {
          settings = settings.copyWith(buildMode: BuildMode.maiaDbExplore);
        } else if (reason == 'cancelled') {
          cancelled = true;
        } else {
          lines = [
            _line(['e4']),
          ];
        }
        final result = await build(builder(), settings: settings, lines: lines);
        expect(result.enrichment, (
          refutations: 0,
          alternatives: 0,
          improvements: 0,
        ));
        expect(pool.budgets, isEmpty);
        expect(pool.discoverMultiPvCalls, isEmpty);
        expect(statuses, isEmpty);
        expect(result.course.entries, isNotEmpty);
      });
    }

    test('a preparation supplier failure still fails the export', () async {
      final failure = StateError('database unavailable during preparation');
      await expectLater(
        build(
          builder(games: () => throw failure),
          settings: config.copyWith(refutationLines: false),
        ),
        throwsA(same(failure)),
      );
      expect(pool.budgets, isEmpty);
    });

    test(
      'failed warmup drops only that pass and later work retries startup',
      () async {
        pool.failFirstWarmup = true;
        final result = await build(builder());
        expect(pool.budgets, [3, 3]);
        expect(result.enrichment, (
          refutations: 0,
          alternatives: 1,
          improvements: 1,
        ));
        expect(result.course.entries.expand((e) => e.refutation), isEmpty);
        expect(result.course.toPgn(), contains('Bc4 improves on Bb5'));
      },
    );

    test(
      'a failed probe and a thrown progress callback both leave later passes usable',
      () async {
        pool.discoveryByFen.remove(_blunder.leafFen);
        final result = await build(
          builder(
            status: (message) {
              statuses.add(message);
              if (message.startsWith('Phase 3.5')) {
                throw StateError('probe progress failed');
              }
            },
          ),
        );
        expect(result.enrichment, (
          refutations: 0,
          alternatives: 1,
          improvements: 1,
        ));
        expect(pool.budgets, [3]);
        expect(statuses.last, startsWith('Phase 3.8'));
      },
    );

    test(
      'cancellation during a pass retains completed findings and skips later work',
      () async {
        final other = _probeLine(['d4', 'd5'], punish: true);
        pool.discoveryByFen[other.leafFen!] = _result(['c2c4']);
        final result = await build(
          builder(
            status: (message) {
              statuses.add(message);
              cancelled = true;
            },
          ),
          lines: [_blunder, other],
        );
        expect(result.enrichment, (
          refutations: 1,
          alternatives: 0,
          improvements: 0,
        ));
        expect(pool.discoverMultiPvCalls, hasLength(1));
        expect(statuses, hasLength(1));
        expect(
          result.course.entries.expand((entry) => entry.refutation),
          contains('Bxf7+'),
        );
      },
    );

    test(
      'consecutive builds read current sources and never carry previous counts',
      () async {
        final owner = builder();
        final first = await build(owner);
        expect(first.enrichment, (
          refutations: 1,
          alternatives: 1,
          improvements: 1,
        ));
        database = null;
        master = null;
        final second = await build(
          owner,
          settings: config.copyWith(refutationLines: false, engineTailPlies: 0),
        );
        expect(second.enrichment, (
          refutations: 0,
          alternatives: 0,
          improvements: 0,
        ));
        expect(
          second.course.entries.expand((entry) => entry.refutedAlternatives),
          isEmpty,
        );
        expect(second.course.toPgn(), isNot(contains('improves on')));
        expect(first.enrichment, (
          refutations: 1,
          alternatives: 1,
          improvements: 1,
        ));
        expect(pool.budgets, [3]);
      },
    );
  });
}

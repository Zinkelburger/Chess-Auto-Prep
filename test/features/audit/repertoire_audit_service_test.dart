/// [RepertoireAuditService] against a small handmade repertoire and scripted
/// engine/ChessDB stand-ins: classification boundaries, eval signs for both
/// colours, mate packing, the engine and ChessDB strong-reply sources, dead
/// ends, the walk shape (maxPly, subtree start, reach probability), and the
/// cancel/resume contract that the session controller's progress snapshot
/// depends on.
library;

import 'dart:async';

import 'package:chess_auto_prep/features/audit/models/audit_finding.dart';
import 'package:chess_auto_prep/features/audit/models/audit_result.dart';
import 'package:chess_auto_prep/features/audit/services/audit_config.dart';
import 'package:chess_auto_prep/features/audit/services/repertoire_audit_service.dart';
import 'package:chess_auto_prep/models/analysis/discovery_result.dart';
import 'package:chess_auto_prep/models/opening_tree.dart';
import 'package:chess_auto_prep/services/eval/db_move_list.dart';
import 'package:chess_auto_prep/services/opening_tree_builder.dart';
import 'package:chess_auto_prep/services/run_control.dart';
import 'package:chess_auto_prep/utils/eval_constants.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../services/generation/engine_fakes.dart';
import '../../support/hunt_harness.dart';

/// A White repertoire: the Ruy Lopez three times, one Sicilian stub. The
/// 3:1 split at Black's first move is what the reach probability tests read.
const _whiteGames = [
  '[Result "*"]\n\n1. e4 e5 2. Nf3 Nc6 3. Bb5 *',
  '[Result "*"]\n\n1. e4 e5 2. Nf3 Nc6 3. Bb5 *',
  '[Result "*"]\n\n1. e4 e5 2. Nf3 Nc6 3. Bb5 *',
  '[Result "*"]\n\n1. e4 c5 2. Nf3 *',
];

/// The same moves read as a Black repertoire.
const _blackGames = ['[Result "*"]\n\n1. e4 e5 2. Nf3 Nc6 *'];

Future<OpeningTree> _build(List<String> games, {required bool white}) =>
    OpeningTreeBuilder.buildTree(
      pgnList: games,
      username: '',
      userIsWhite: white,
      strictPlayerMatching: false,
      maxDepth: 20,
    );

/// Every source off; tests switch on the one they exercise.
const _quiet = AuditConfig(
  useStockfish: false,
  useMaia: false,
  useLichessDb: false,
  useChessDb: false,
);

DiscoveryLine _mateLine(int pvNumber, int mateWhite, String uci) =>
    DiscoveryLine(
      pvNumber: pvNumber,
      depth: 14,
      scoreMate: mateWhite,
      pv: [uci],
    );

class _ScriptedDb implements ExternalMoveProvider {
  _ScriptedDb(this.byFen);

  /// Keyed by the first four FEN fields.
  final Map<String, List<DbMove>> byFen;
  final List<String> calls = [];

  static String key(String fen) => fen.split(' ').take(4).join(' ');

  @override
  Future<DbMoveList> lookupMoves(String fen) async {
    calls.add(key(fen));
    final moves = byFen[key(fen)];
    if (moves == null) return DbMoveList.empty;
    return DbMoveList(
      moves: DbMoveList.sorted(moves),
      source: DbMoveSource.chessDbApi,
    );
  }
}

/// A pool whose discovery on one position parks until the test releases it,
/// so a cancel can land while that node's engine call is in flight.
class _HoldingPool extends FakeStockfishPool {
  String? holdFen;
  final started = Completer<void>();
  final unblock = Completer<void>();

  /// Every position handed to a MultiPV search, in order.
  final discoveryFens = <String>[];

  @override
  Future<DiscoveryResult> discoverMoves({
    required String fen,
    required int depth,
    required int multiPv,
    required bool isWhiteToMove,
    List<String>? searchMoves,
    void Function(DiscoveryResult)? onProgress,
  }) async {
    discoveryFens.add(fen);
    if (fen == holdFen) {
      if (!started.isCompleted) started.complete();
      await unblock.future;
    }
    return super.discoverMoves(
      fen: fen,
      depth: depth,
      multiPv: multiPv,
      isWhiteToMove: isWhiteToMove,
      searchMoves: searchMoves,
      onProgress: onProgress,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late OpeningTree white;

  OpeningTreeNode at(OpeningTree tree, List<String> path) {
    var node = tree.root;
    for (final san in path) {
      node = node.children[san]!;
    }
    return node;
  }

  setUp(() async {
    await clearEvalCache();
    white = await _build(_whiteGames, white: true);
  });

  Future<AuditResult> run(
    OpeningTree tree, {
    required bool isWhite,
    FakeStockfishPool? pool,
    ExternalMoveProvider? db,
    AuditConfig config = _quiet,
    String? startFen,
    Set<String> skipFens = const {},
    List<AuditFinding> priorFindings = const [],
    void Function(AuditProgress)? onProgress,
  }) =>
      RepertoireAuditService(
        pool: pool ?? FakeStockfishPool(),
        chessDbProvider: db,
      ).audit(
        tree: tree,
        isWhiteRepertoire: isWhite,
        config: config,
        startFen: startFen,
        skipFens: skipFens,
        priorFindings: priorFindings,
        onProgress: onProgress,
      );

  List<AuditFinding> ofType(AuditResult r, AuditFindingType t) =>
      r.findings.where((f) => f.type == t).toList();

  group('walk shape (no sources)', () {
    test('counts our, opponent and leaf nodes over the whole tree', () async {
      final progress = <AuditProgress>[];
      final result = await run(white, isWhite: true, onProgress: progress.add);

      // root, e4, e5, c5, Nf3, Nf3, Nc6, Bb5.
      expect(result.nodesChecked, 8);
      // Non-leaf White-to-move: root, e5, c5, Nc6.
      expect(result.ourMoveNodesChecked, 4);
      // Non-leaf Black-to-move: e4, 2.Nf3 (Ruy line).
      expect(result.opponentNodesChecked, 2);
      // 2.Nf3 (Sicilian stub) and 3.Bb5.
      expect(result.leafNodesChecked, 2);
      expect(result.findings, isEmpty);

      final last = progress.last;
      expect(last.totalNodes, 8);
      expect(last.nodesChecked, 8);
      expect(last.percent, 100);
    });

    test('maxPly bounds both the walk and the progress total', () async {
      AuditProgress? last;
      final result = await run(
        white,
        isWhite: true,
        config: _quiet.copyWith(maxPly: 2),
        onProgress: (p) => last = p,
      );

      // root(0), e4(1), e5(2), c5(2).
      expect(result.nodesChecked, 4);
      expect(last!.totalNodes, 4);
      expect(result.leafNodesChecked, 0, reason: 'pruned nodes are not leaves');
    });

    test('a subtree start walks from that node with its full path', () async {
      final start = at(white, ['e4', 'e5']);
      final result = await run(white, isWhite: true, startFen: start.fen);
      // e5, Nf3, Nc6, Bb5.
      expect(result.nodesChecked, 4);
    });

    test('a start position the tree never reached audits nothing', () async {
      final result = await run(
        white,
        isWhite: true,
        startFen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR b KQkq - 0 1',
      );
      expect(result.nodesChecked, 0);
      expect(result.findings, isEmpty);
    });
  });

  group('our-move quality (Stockfish)', () {
    /// Script the position after 1.e4 e5: best is Bc4 at [bestCp], the
    /// repertoire's Nf3 at [nf3Cp] (both White-POV).
    FakeStockfishPool scriptAfterE5({required int bestCp, required int nf3Cp}) {
      final pool = FakeStockfishPool();
      pool.discoveryByFen[at(white, ['e4', 'e5']).fen] = DiscoveryResult(
        lines: [
          discoveryLine(pvNumber: 1, cpWhite: bestCp, pv: ['f1c4']),
          discoveryLine(pvNumber: 2, cpWhite: nf3Cp, pv: ['g1f3']),
        ],
        depth: 14,
      );
      return pool;
    }

    final cfg = _quiet.copyWith(
      useStockfish: true,
      mistakeThresholdCp: 100,
      inaccuracyThresholdCp: 40,
    );

    test(
      'a loss exactly at the inaccuracy threshold is an inaccuracy',
      () async {
        final result = await run(
          white,
          isWhite: true,
          pool: scriptAfterE5(bestCp: 60, nf3Cp: 20),
          config: cfg,
        );

        final f = ofType(result, AuditFindingType.inaccuracy).single;
        expect(f.severity, AuditSeverity.warning);
        expect(f.ourMove, 'Nf3');
        expect(f.bestMove, 'Bc4');
        expect(f.evalLossCp, 40);
        expect(f.positionEvalCp, 20);
        expect(f.bestMoveEvalCp, 60);
        expect(f.movePath, ['e4', 'e5', 'Nf3']);
        expect(f.fen, at(white, ['e4', 'e5']).fen);
        // 1...e5 is 3 of 4 games; our own moves never attenuate reach.
        expect(f.cumulativeProbability, closeTo(0.75, 1e-9));
        expect(ofType(result, AuditFindingType.mistake), isEmpty);
      },
    );

    test('one centipawn under the inaccuracy threshold is nothing', () async {
      final result = await run(
        white,
        isWhite: true,
        pool: scriptAfterE5(bestCp: 60, nf3Cp: 21),
        config: cfg,
      );
      expect(result.findings, isEmpty);
    });

    test('a loss exactly at the mistake threshold is a mistake', () async {
      final result = await run(
        white,
        isWhite: true,
        pool: scriptAfterE5(bestCp: 100, nf3Cp: 0),
        config: cfg,
      );

      final f = ofType(result, AuditFindingType.mistake).single;
      expect(f.severity, AuditSeverity.critical);
      expect(f.evalLossCp, 100);
      expect(ofType(result, AuditFindingType.inaccuracy), isEmpty);
    });

    test('the loss is measured from Black\'s side for a Black file', () async {
      final black = await _build(_blackGames, white: false);
      // Black to move after 2.Nf3: engine says Nf6 (-30 White-POV) is best
      // for Black; the file's Nc6 sits at +20. Black loses 50.
      final node = at(black, ['e4', 'e5', 'Nf3']);
      final pool = FakeStockfishPool();
      pool.discoveryByFen[node.fen] = DiscoveryResult(
        lines: [
          discoveryLine(pvNumber: 1, cpWhite: -30, pv: ['g8f6']),
          discoveryLine(pvNumber: 2, cpWhite: 20, pv: ['b8c6']),
        ],
        depth: 14,
      );

      final result = await run(black, isWhite: false, pool: pool, config: cfg);

      final f = ofType(result, AuditFindingType.inaccuracy).single;
      expect(f.ourMove, 'Nc6');
      expect(f.bestMove, 'Nf6');
      expect(f.evalLossCp, 50, reason: 'repCp - bestCp for Black');
      expect(f.positionEvalCp, 20, reason: 'stored White-POV');
      expect(f.bestMoveEvalCp, -30);
    });

    test('weak position is strict and from our side', () async {
      final black = await _build(_blackGames, white: false);
      final node = at(black, ['e4', 'e5', 'Nf3']);

      Future<List<AuditFinding>> weakAt(int nc6White) async {
        final pool = FakeStockfishPool();
        pool.discoveryByFen[node.fen] = DiscoveryResult(
          lines: [
            discoveryLine(pvNumber: 1, cpWhite: nc6White, pv: ['b8c6']),
          ],
          depth: 14,
        );
        final result = await run(
          black,
          isWhite: false,
          pool: pool,
          config: cfg.copyWith(weakPositionThresholdCp: -150),
        );
        return ofType(result, AuditFindingType.weakPosition);
      }

      // Exactly at the threshold: not weak (strict <).
      expect(await weakAt(150), isEmpty);

      final weak = (await weakAt(151)).single;
      expect(weak.positionEvalCp, 151);
      expect(
        weak.fen,
        at(black, ['e4', 'e5', 'Nf3', 'Nc6']).fen,
        reason: 'a weak position points at the position after our move',
      );
      expect(weak.movePath, ['e4', 'e5', 'Nf3', 'Nc6']);
    });

    test('a repertoire move outside MultiPV is evaluated after the move and '
        'cached for the next run', () async {
      final parent = at(white, ['e4', 'e5']);
      final child = at(white, ['e4', 'e5', 'Nf3']);
      final pool = FakeStockfishPool();
      pool.discoveryByFen[parent.fen] = DiscoveryResult(
        lines: [
          discoveryLine(pvNumber: 1, cpWhite: 60, pv: ['f1c4']),
          discoveryLine(pvNumber: 2, cpWhite: 50, pv: ['d2d4']),
        ],
        depth: 14,
      );
      // After 2.Nf3 it is Black to move; the engine speaks for Black.
      pool.stmCpByFen[child.fen] = -10;

      final first = await run(white, isWhite: true, pool: pool, config: cfg);

      final f = ofType(first, AuditFindingType.inaccuracy).single;
      expect(f.positionEvalCp, 10, reason: 'STM -10 for Black is +10 White');
      expect(f.evalLossCp, 50);
      expect(pool.evalCalls, [child.fen]);
      expect(first.evalCacheHits, 0);
      expect(first.evalCacheMisses, 2, reason: 'discovery + one eval');

      // Same discovery, but no eval scripted: the cache must answer.
      final pool2 = FakeStockfishPool();
      pool2.discoveryByFen[parent.fen] = pool.discoveryByFen[parent.fen]!;
      final second = await run(white, isWhite: true, pool: pool2, config: cfg);

      expect(pool2.evalCalls, isEmpty);
      expect(second.evalCacheHits, 1);
      expect(
        ofType(second, AuditFindingType.inaccuracy).single.positionEvalCp,
        10,
      );
    });

    test('a forced mate for us makes the file\'s move a mistake', () async {
      final parent = at(white, ['e4', 'e5']);
      final pool = FakeStockfishPool();
      pool.discoveryByFen[parent.fen] = DiscoveryResult(
        lines: [
          _mateLine(1, 3, 'f1c4'),
          discoveryLine(pvNumber: 2, cpWhite: 20, pv: ['g1f3']),
        ],
        depth: 14,
      );

      final result = await run(white, isWhite: true, pool: pool, config: cfg);

      final f = ofType(result, AuditFindingType.mistake).single;
      expect(f.bestMoveEvalCp, kMateCpBase - 3);
      expect(f.evalLossCp, kMateCpBase - 3 - 20);
      expect(f.bestMove, 'Bc4');
    });

    test('a mate against us reported off-MultiPV is a weak position', () async {
      final parent = at(white, ['e4', 'e5']);
      final child = at(white, ['e4', 'e5', 'Nf3']);
      final pool = FakeStockfishPool();
      pool.discoveryByFen[parent.fen] = DiscoveryResult(
        lines: [
          discoveryLine(pvNumber: 1, cpWhite: 30, pv: ['f1c4']),
        ],
        depth: 14,
      );
      // Black to move after 2.Nf3 and Black mates in 2.
      pool.stmMateByFen[child.fen] = 2;

      final result = await run(white, isWhite: true, pool: pool, config: cfg);

      final weak = ofType(result, AuditFindingType.weakPosition).single;
      expect(weak.positionEvalCp, -(kMateCpBase - 2));
      final mistake = ofType(result, AuditFindingType.mistake).single;
      expect(mistake.evalLossCp, 30 + kMateCpBase - 2);
    });

    test('an engine failure at one position is swallowed, not fatal', () async {
      // Nothing scripted: every discovery throws inside the service.
      final result = await run(
        white,
        isWhite: true,
        pool: FakeStockfishPool(),
        config: cfg,
      );
      expect(result.findings, isEmpty);
      expect(result.nodesChecked, 8);
      expect(result.ourMoveNodesChecked, 4);
    });
  });

  group('opponent coverage — engine source', () {
    test(
      'the window is inclusive and the gap is from the opponent\'s side',
      () async {
        // Black to move after 1.e4; the file answers e5 and c5.
        final node = at(white, ['e4']);
        final pool = FakeStockfishPool();
        pool.discoveryByFen[node.fen] = DiscoveryResult(
          lines: [
            discoveryLine(pvNumber: 1, cpWhite: -10, pv: ['c7c5']), // covered
            discoveryLine(pvNumber: 2, cpWhite: 0, pv: ['g8f6']), // gap 10
            discoveryLine(pvNumber: 3, cpWhite: 0, pv: ['e7e5']), // covered
            discoveryLine(pvNumber: 4, cpWhite: 40, pv: ['d7d6']), // gap 50
            discoveryLine(pvNumber: 5, cpWhite: 41, pv: ['b8c6']), // gap 51
          ],
          depth: 14,
        );

        final result = await run(
          white,
          isWhite: true,
          pool: pool,
          config: _quiet.copyWith(useStockfish: true, strongReplyWindowCp: 50),
        );

        final missing = ofType(result, AuditFindingType.missingResponse);
        expect(missing.map((f) => f.missingMove), ['Nf6', 'd6']);

        final nf6 = missing[0];
        expect(nf6.source, MissingResponseSource.engine);
        expect(nf6.severity, AuditSeverity.critical, reason: 'gap <= 10');
        expect(nf6.evalLossCp, 10);
        expect(nf6.positionEvalCp, 0, reason: 'White-POV');
        expect(nf6.bestMoveEvalCp, -10);
        expect(nf6.movePath, ['e4']);
        expect(nf6.cumulativeProbability, 1.0);

        final d6 = missing[1];
        expect(d6.severity, AuditSeverity.warning);
        expect(d6.evalLossCp, 50);
      },
    );
  });

  group('opponent coverage — ChessDB source', () {
    test('a Black-to-move node stores White-POV evals', () async {
      final node = at(white, ['e4']);
      final db = _ScriptedDb({
        _ScriptedDb.key(node.fen): const [
          DbMove(uci: 'c7c5', san: 'c5', stmCp: 10),
          DbMove(uci: 'e7e5', san: 'e5', stmCp: 0),
          DbMove(uci: 'g8f6', san: 'Nf6', stmCp: -5),
          DbMove(uci: 'd7d5', san: 'd5', stmCp: -100),
        ],
      });

      final result = await run(
        white,
        isWhite: true,
        db: db,
        config: _quiet.copyWith(useChessDb: true, strongReplyWindowCp: 50),
      );

      final f = ofType(result, AuditFindingType.missingResponse).single;
      expect(f.missingMove, 'Nf6');
      expect(f.evalLossCp, 15);
      expect(f.severity, AuditSeverity.warning, reason: 'gap > 10');
      expect(f.positionEvalCp, 5, reason: 'Black\'s -5 is White\'s +5');
      expect(f.bestMoveEvalCp, -10);
      expect(f.continuationCount, 3);
      // Only opponent-to-move nodes are asked.
      expect(db.calls, contains(_ScriptedDb.key(node.fen)));
      expect(db.calls.any((k) => k.split(' ')[1] == 'w'), isFalse);
    });

    test(
      'a level uncovered move is only critical where few moves hold',
      () async {
        final node = at(white, ['e4']);
        Future<AuditSeverity> severityWith(List<DbMove> moves) async {
          final db = _ScriptedDb({_ScriptedDb.key(node.fen): moves});
          final result = await run(
            white,
            isWhite: true,
            db: db,
            config: _quiet.copyWith(useChessDb: true, strongReplyWindowCp: 50),
          );
          return ofType(
            result,
            AuditFindingType.missingResponse,
          ).firstWhere((f) => f.missingMove == 'Nf6').severity;
        }

        expect(
          await severityWith(const [
            DbMove(uci: 'e7e5', san: 'e5', stmCp: 0),
            DbMove(uci: 'g8f6', san: 'Nf6', stmCp: 0),
          ]),
          AuditSeverity.critical,
        );
        expect(
          await severityWith(const [
            DbMove(uci: 'e7e5', san: 'e5', stmCp: 0),
            DbMove(uci: 'g8f6', san: 'Nf6', stmCp: 0),
            DbMove(uci: 'd7d6', san: 'd6', stmCp: 0),
            DbMove(uci: 'b8c6', san: 'Nc6', stmCp: 0),
            DbMove(uci: 'g7g6', san: 'g6', stmCp: 0),
          ]),
          AuditSeverity.warning,
          reason: 'five level moves: the position is quiet, not sharp',
        );
      },
    );
  });

  group('dead ends', () {
    final leaf = ['e4', 'c5', 'Nf3'];

    Future<List<AuditFinding>> deadEndsWith(List<DbMove> moves) async {
      final node = at(white, leaf);
      final db = _ScriptedDb({_ScriptedDb.key(node.fen): moves});
      final result = await run(
        white,
        isWhite: true,
        db: db,
        config: _quiet.copyWith(
          useChessDb: true,
          strongReplyWindowCp: 50,
          deadEndMinContinuations: 2,
        ),
      );
      return ofType(result, AuditFindingType.deadEnd);
    }

    test('an opponent leaf with strong continuations is a dead end', () async {
      final f = (await deadEndsWith(const [
        DbMove(uci: 'd7d6', san: 'd6', stmCp: 0),
        DbMove(uci: 'b8c6', san: 'Nc6', stmCp: 0),
        DbMove(uci: 'e7e6', san: 'e6', stmCp: -5),
        DbMove(uci: 'g7g6', san: 'g6', stmCp: -100),
      ])).single;

      expect(f.continuationCount, 3);
      expect(f.uncoveredMoves, ['Nc6', 'd6', 'e6'], reason: 'sorted');
      expect(f.severity, AuditSeverity.info, reason: 'fewer than four');
      expect(f.movePath, leaf);
      expect(f.cumulativeProbability, closeTo(0.25, 1e-9));
    });

    test('four or more continuations is a warning', () async {
      final f = (await deadEndsWith(const [
        DbMove(uci: 'd7d6', san: 'd6', stmCp: 0),
        DbMove(uci: 'b8c6', san: 'Nc6', stmCp: 0),
        DbMove(uci: 'e7e6', san: 'e6', stmCp: -5),
        DbMove(uci: 'g7g6', san: 'g6', stmCp: -10),
      ])).single;
      expect(f.severity, AuditSeverity.warning);
    });

    test('below the minimum is not a dead end', () async {
      expect(
        await deadEndsWith(const [DbMove(uci: 'd7d6', san: 'd6', stmCp: 0)]),
        isEmpty,
      );
    });
  });

  group('cancel and resume', () {
    test(
      'skipped positions are not re-checked but their children are',
      () async {
        final e5 = at(white, ['e4', 'e5']);
        final nc6 = at(white, ['e4', 'e5', 'Nf3', 'Nc6']);
        final pool = _HoldingPool();
        for (final node in [e5, nc6]) {
          pool.discoveryByFen[node.fen] = DiscoveryResult(
            lines: [
              discoveryLine(pvNumber: 1, cpWhite: 200, pv: ['h2h4']),
              discoveryLine(
                pvNumber: 2,
                cpWhite: 0,
                pv: [node == e5 ? 'g1f3' : 'f1b5'],
              ),
            ],
            depth: 14,
          );
        }
        final prior = AuditFinding(
          type: AuditFindingType.mistake,
          severity: AuditSeverity.critical,
          movePath: const ['e4', 'e5', 'Nf3'],
          fen: e5.fen,
          ourMove: 'Nf3',
        );

        final result = await run(
          white,
          isWhite: true,
          pool: pool,
          config: _quiet.copyWith(useStockfish: true),
          skipFens: {e5.fen},
          priorFindings: [prior],
        );

        expect(pool.discoveryFens, isNot(contains(e5.fen)));
        expect(pool.discoveryFens, contains(nc6.fen));
        expect(
          pool.discoveryFens,
          contains(at(white, ['e4', 'e5', 'Nf3']).fen),
          reason: 'children of a skipped node are still walked',
        );
        final mistakes = ofType(result, AuditFindingType.mistake);
        expect(mistakes.map((f) => f.ourMove), ['Nf3', 'Bb5']);
        expect(identical(mistakes.first, prior), isTrue);
        expect(result.nodesChecked, 8, reason: 'skipped nodes still count');
        expect(
          RepertoireAuditService(pool: pool).checkedFens,
          isEmpty,
          reason: 'a fresh service has no checked positions',
        );
      },
    );

    test('a position is only "checked" once its findings exist', () async {
      // The controller snapshots `checkedFens` + the findings it has heard
      // about at the moment of cancel. A node whose engine call is still in
      // flight must not be in that set yet, or its findings are lost and the
      // resumed run skips the position for good.
      final e5 = at(white, ['e4', 'e5']);
      final pool = _HoldingPool()..holdFen = e5.fen;
      pool.discoveryByFen[e5.fen] = DiscoveryResult(
        lines: [
          discoveryLine(pvNumber: 1, cpWhite: 200, pv: ['h2h4']),
          discoveryLine(pvNumber: 2, cpWhite: 0, pv: ['g1f3']),
        ],
        depth: 14,
      );
      final service = RepertoireAuditService(pool: pool);
      final heard = <AuditFinding>[];

      final pending = service.audit(
        tree: white,
        isWhiteRepertoire: true,
        config: _quiet.copyWith(useStockfish: true),
        onFinding: heard.add,
      );
      await pool.started.future;

      // Cancel lands while 1.e4 e5 is being evaluated.
      service.cancel();
      final snapshotFens = service.checkedFens;
      final snapshotFindings = List.of(heard);
      expect(snapshotFens, contains(white.root.fen));
      expect(snapshotFens, contains(at(white, ['e4']).fen));
      expect(
        snapshotFens,
        isNot(contains(e5.fen)),
        reason: 'its check has not finished',
      );
      expect(snapshotFindings, isEmpty);

      pool.unblock.complete();
      final result = await pending;

      // After the run returns, the in-flight node is checked and its
      // finding is in the result: the two views are each self-consistent.
      expect(service.checkedFens, contains(e5.fen));
      expect(ofType(result, AuditFindingType.mistake).single.ourMove, 'Nf3');
      expect(result.nodesChecked, lessThan(8));

      // Resuming from the cancel-time snapshot finds it exactly once.
      final resumedPool = FakeStockfishPool();
      resumedPool.discoveryByFen[e5.fen] = pool.discoveryByFen[e5.fen]!;
      final resumed = await run(
        white,
        isWhite: true,
        pool: resumedPool,
        config: _quiet.copyWith(useStockfish: true),
        skipFens: snapshotFens,
        priorFindings: snapshotFindings,
      );
      expect(ofType(resumed, AuditFindingType.mistake).map((f) => f.ourMove), [
        'Nf3',
      ]);
    });

    test('a paused run holds at the next checkpoint; cancel ends it', () async {
      final e5 = at(white, ['e4', 'e5']);
      final pool = _HoldingPool()..holdFen = e5.fen;
      pool.discoveryByFen[e5.fen] = const DiscoveryResult(lines: [], depth: 14);
      final service = RepertoireAuditService(pool: pool);
      final progress = <AuditProgress>[];

      final pending = service.audit(
        tree: white,
        isWhiteRepertoire: true,
        config: _quiet.copyWith(useStockfish: true),
        onProgress: progress.add,
      );
      await pool.started.future;
      service.pause();
      pool.unblock.complete();

      // The in-flight node finishes, then the loop parks at the checkpoint.
      await Future<void>.delayed(RunControl.pollInterval * 3);
      expect(service.checkedFens, contains(e5.fen));
      expect(service.checkedFens.length, 3, reason: 'root, e4, e5 only');

      service.cancel();
      final result = await pending;
      expect(result.nodesChecked, 3);
      expect(progress.last.nodesChecked, 3);
    });
  });
}

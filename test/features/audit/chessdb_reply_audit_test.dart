/// The audit's "strong reply" sources: an uncovered opponent reply that
/// ChessDB or Stockfish's MultiPV scores close to their best is a finding,
/// whether or not anyone plays it.
library;

import 'package:chess_auto_prep/features/audit/models/audit_finding.dart';
import 'package:chess_auto_prep/features/audit/services/audit_config.dart';
import 'package:chess_auto_prep/features/audit/services/repertoire_audit_service.dart';
import 'package:chess_auto_prep/models/analysis/discovery_result.dart';
import 'package:chess_auto_prep/models/opening_tree.dart';
import 'package:chess_auto_prep/services/eval/db_move_list.dart';
import 'package:chess_auto_prep/services/opening_tree_builder.dart';
import 'package:chess_auto_prep/utils/fen_utils.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../services/generation/engine_fakes.dart';

/// A Black repertoire with one answer to 6...d6: the main line 7.exd6.
const _line =
    '[Result "*"]\n\n'
    '1. e4 e5 2. Nf3 Nc6 3. Bc4 Nf6 4. d4 exd4 5. e5 Ng4 6. O-O d6 '
    '7. exd6 Qxd6 *';

/// White to move after 6...d6. ChessDB (Sept 2026): exd6 +1, Bg5 0, then
/// nothing better than -80.
const _afterD6 = 'r1bqkb1r/ppp2ppp/2np4/4P3/2Bp2n1/5N2/PPP2PPP/RNBQ1RK1 w kq -';

String _fen4(String fen) => fen.split(' ').take(4).join(' ');

class _Scripted implements ExternalMoveProvider {
  _Scripted(this.byFen);

  final Map<String, List<DbMove>> byFen;
  final List<String> calls = [];

  @override
  Future<DbMoveList> lookupMoves(String fen) async {
    calls.add(_fen4(fen));
    final moves = byFen[_fen4(fen)];
    if (moves == null) return DbMoveList.empty;
    return DbMoveList(
      moves: DbMoveList.sorted(moves),
      source: DbMoveSource.chessDbApi,
    );
  }
}

Future<OpeningTree> _tree() => OpeningTreeBuilder.buildTree(
  pgnList: const [_line],
  username: '',
  userIsWhite: false,
  strictPlayerMatching: false,
  maxDepth: 20,
);

const _config = AuditConfig(
  useStockfish: false,
  useMaia: false,
  useLichessDb: false,
  useChessDb: true,
  strongReplyWindowCp: 50,
);

void main() {
  test(
    'an uncovered reply inside the window is a strong-reply finding',
    () async {
      final db = _Scripted({
        _afterD6: const [
          DbMove(uci: 'e5d6', san: 'exd6', stmCp: 1),
          DbMove(uci: 'c1g5', san: 'Bg5', stmCp: 0),
          DbMove(uci: 'f3d4', san: 'Nxd4', stmCp: -80),
        ],
      });
      final service = RepertoireAuditService(chessDbProvider: db);

      final result = await service.audit(
        tree: await _tree(),
        isWhiteRepertoire: false,
        config: _config,
      );

      final missing = result.findings
          .where((f) => f.type == AuditFindingType.missingResponse)
          .toList();
      expect(missing.map((f) => f.missingMove), ['Bg5']);

      final bg5 = missing.single;
      expect(bg5.source, MissingResponseSource.chessDb);
      expect(bg5.severity, AuditSeverity.critical);
      expect(bg5.evalLossCp, 1);
      expect(bg5.positionEvalCp, 0);
      expect(bg5.bestMoveEvalCp, 1);
      expect(bg5.movePath.last, 'd6');
      expect(bg5.summary, contains('Strong reply: 7. Bg5'));
      expect(bg5.continuationCount, 2);
      expect(
        bg5.summary,
        contains('1cp behind their best · 2 good moves here'),
      );

      // Every White-to-move node was asked; no Black-to-move node was.
      expect(db.calls, contains(_afterD6));
      expect(
        db.calls.any((f) => f.split(' ')[1] == 'b'),
        isFalse,
        reason: 'ChessDB is only consulted where the opponent moves',
      );
    },
  );

  test(
    'a reply the window excludes, or the file covers, is not flagged',
    () async {
      final db = _Scripted({
        _afterD6: const [
          DbMove(uci: 'e5d6', san: 'exd6', stmCp: 1),
          DbMove(uci: 'c1g5', san: 'Bg5', stmCp: -60),
        ],
      });
      final service = RepertoireAuditService(chessDbProvider: db);

      final result = await service.audit(
        tree: await _tree(),
        isWhiteRepertoire: false,
        config: _config,
      );

      expect(
        result.findings.where(
          (f) => f.type == AuditFindingType.missingResponse,
        ),
        isEmpty,
      );
    },
  );

  test('the source is never consulted when switched off', () async {
    final db = _Scripted({
      _afterD6: const [DbMove(uci: 'c1g5', san: 'Bg5', stmCp: 0)],
    });
    final service = RepertoireAuditService(chessDbProvider: db);

    await service.audit(
      tree: await _tree(),
      isWhiteRepertoire: false,
      config: _config.copyWith(useChessDb: false),
    );

    expect(db.calls, isEmpty);
  });

  group('engine source', () {
    test(
      'a MultiPV line inside the window is a strong-reply finding',
      () async {
        final tree = await _tree();
        final node = tree.fenToNodes[normalizeFen(_afterD6)]!.single;
        // Stockfish 17 at depth 14, White-POV: exd6 +45, Bg5 +4, Bb5 -55.
        final pool = FakeStockfishPool();
        pool.discoveryByFen[node.fen] = DiscoveryResult(
          lines: [
            discoveryLine(pvNumber: 1, cpWhite: 45, pv: ['e5d6']),
            discoveryLine(pvNumber: 2, cpWhite: 4, pv: ['c1g5']),
            discoveryLine(pvNumber: 3, cpWhite: -55, pv: ['c4b5']),
          ],
          depth: 14,
        );
        final service = RepertoireAuditService(pool: pool);

        final result = await service.audit(
          tree: tree,
          isWhiteRepertoire: false,
          config: _config.copyWith(useStockfish: true, useChessDb: false),
        );

        final missing = result.findings
            .where((f) => f.type == AuditFindingType.missingResponse)
            .toList();
        expect(missing.map((f) => f.missingMove), ['Bg5']);
        final bg5 = missing.single;
        expect(bg5.source, MissingResponseSource.engine);
        expect(bg5.evalLossCp, 41);
        expect(bg5.severity, AuditSeverity.warning);
        expect(bg5.positionEvalCp, 4);
        expect(bg5.bestMoveEvalCp, 45);
        expect(bg5.summary, contains('Strong reply: 7. Bg5'));
        expect(bg5.summary, contains('Stockfish: 41cp behind their best'));
      },
    );

    test('a move ChessDB already reported is not reported twice', () async {
      final tree = await _tree();
      final node = tree.fenToNodes[normalizeFen(_afterD6)]!.single;
      final pool = FakeStockfishPool();
      pool.discoveryByFen[node.fen] = DiscoveryResult(
        lines: [
          discoveryLine(pvNumber: 1, cpWhite: 45, pv: ['e5d6']),
          discoveryLine(pvNumber: 2, cpWhite: 4, pv: ['c1g5']),
        ],
        depth: 14,
      );
      final db = _Scripted({
        _afterD6: const [
          DbMove(uci: 'e5d6', san: 'exd6', stmCp: 1),
          DbMove(uci: 'c1g5', san: 'Bg5', stmCp: 0),
        ],
      });
      final service = RepertoireAuditService(chessDbProvider: db, pool: pool);

      final result = await service.audit(
        tree: tree,
        isWhiteRepertoire: false,
        config: _config.copyWith(useStockfish: true),
      );

      final bg5 = result.findings.where((f) => f.missingMove == 'Bg5').toList();
      expect(bg5.length, 1);
      expect(bg5.single.source, MissingResponseSource.chessDb);
    });
  });

  test('config and finding round-trip through their maps', () {
    final config = AuditConfig.fromMap(
      const AuditConfig(useChessDb: false, strongReplyWindowCp: 12).toMap(),
    );
    expect(config.useChessDb, isFalse);
    expect(config.strongReplyWindowCp, 12);
    expect(AuditConfig.fromMap(const {}).strongReplyWindowCp, 50);
    expect(AuditConfig.fromMap(const {}).useChessDb, isTrue);

    final finding = AuditFinding.fromJson(
      AuditFinding(
        type: AuditFindingType.missingResponse,
        severity: AuditSeverity.warning,
        movePath: const ['e4'],
        fen: _afterD6,
        missingMove: 'Bg5',
        evalLossCp: 0,
        source: MissingResponseSource.chessDb,
      ).toJson(),
    );
    expect(finding.source, MissingResponseSource.chessDb);
    expect(finding.summary, contains('equal to their best'));
  });
}

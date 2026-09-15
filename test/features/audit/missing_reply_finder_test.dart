/// [MissingReplyFinder]: the audit's opponent-side sources on their own —
/// which uncovered replies each source flags, that the first source to name
/// a move owns it, the ChessDB/engine severity rules, the clash tree, the
/// transposition flag, and the dead-end continuation count.
library;

import 'package:chess_auto_prep/features/audit/models/audit_finding.dart';
import 'package:chess_auto_prep/features/audit/services/audit_config.dart';
import 'package:chess_auto_prep/features/audit/services/engine_position_probe.dart';
import 'package:chess_auto_prep/features/audit/services/missing_reply_finder.dart';
import 'package:chess_auto_prep/features/audit/services/repertoire_walk.dart';
import 'package:chess_auto_prep/models/analysis/discovery_result.dart';
import 'package:chess_auto_prep/models/opening_tree.dart';
import 'package:chess_auto_prep/services/eval/db_move_list.dart';
import 'package:chess_auto_prep/services/eval_cache.dart';
import 'package:chess_auto_prep/services/opening_tree_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/generation/engine_fakes.dart';
import '../../support/hunt_harness.dart';

/// A White repertoire answering only 1...e5 and 1...c5 after 1.e4, with a
/// 2.Nf3 e6 line so that 1...e6 2.Nf3?! transposes nowhere but 1.e4 e6 can
/// be checked for transposition into the tree.
const _games = [
  '[Result "*"]\n\n1. e4 e5 2. Nf3 *',
  '[Result "*"]\n\n1. e4 c5 2. Nf3 *',
];

/// Every book game answers 1.e4 with 1...e6 twice and 1...c5 once.
const _clashGames = [
  '[Result "*"]\n\n1. e4 e6 2. d4 *',
  '[Result "*"]\n\n1. e4 e6 2. d4 *',
  '[Result "*"]\n\n1. e4 c5 2. Nf3 *',
];

Future<OpeningTree> _build(List<String> games) => OpeningTreeBuilder.buildTree(
  pgnList: games,
  username: '',
  userIsWhite: true,
  strictPlayerMatching: false,
  maxDepth: 10,
);

class _ScriptedDb implements ExternalMoveProvider {
  _ScriptedDb(this.byFen);

  final Map<String, List<DbMove>> byFen;
  final List<String> calls = [];

  @override
  Future<DbMoveList> lookupMoves(String fen) async {
    calls.add(fen);
    final moves = byFen[fen];
    if (moves == null) return DbMoveList.empty;
    return DbMoveList(
      moves: DbMoveList.sorted(moves),
      source: DbMoveSource.chessDbApi,
    );
  }
}

const _quiet = AuditConfig(
  useStockfish: false,
  useMaia: false,
  useLichessDb: false,
  useChessDb: false,
);

void main() {
  late OpeningTree tree;
  late FakeStockfishPool pool;
  late List<String> warnings;

  setUpAll(initTestSqlite);

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await clearEvalCache();
    tree = await _build(_games);
    pool = FakeStockfishPool();
    warnings = [];
  });

  /// The opponent-to-move position after 1.e4, as the walk would hand it over.
  RepertoireWalkEntry afterE4() => RepertoireWalkEntry(
    node: tree.root.children['e4']!,
    movePath: const ['e4'],
    ply: 1,
    cumulativeProbability: 0.5,
  );

  MissingReplyFinder finder(
    AuditConfig config, {
    ExternalMoveProvider? db,
    OpeningTree? clashTree,
  }) => MissingReplyFinder(
    config: config,
    tree: tree,
    probe: EnginePositionProbe(pool: pool, evalCache: EvalCache.instance),
    warn: warnings.add,
    chessDb: db,
    clashTree: clashTree,
  );

  void scriptEngineAfterE4(List<(int cpWhite, String uci)> lines) {
    pool.discoveryByFen[afterE4().fen] = DiscoveryResult(
      lines: [
        for (final (i, (cp, uci)) in lines.indexed)
          discoveryLine(pvNumber: i + 1, cpWhite: cp, pv: [uci]),
      ],
      depth: 14,
    );
  }

  group('engine source', () {
    test('flags MultiPV replies inside the window the file lacks', () async {
      // Black to move: White-POV scores, so -20 is Black's best.
      scriptEngineAfterE4([
        (-20, 'e7e5'), // covered
        (-15, 'e7e6'), // 5cp behind → critical
        (10, 'g8f6'), // 30cp behind → warning
        (40, 'a7a6'), // 60cp behind → outside the window
      ]);

      final found = await finder(
        _quiet.copyWith(useStockfish: true, strongReplyWindowCp: 50),
      ).missingReplies(afterE4());

      expect(found.map((f) => f.missingMove), ['e6', 'Nf6']);
      expect(found.map((f) => f.severity), [
        AuditSeverity.critical,
        AuditSeverity.warning,
      ]);
      final e6 = found.first;
      expect(e6.type, AuditFindingType.missingResponse);
      expect(e6.source, MissingResponseSource.engine);
      expect(e6.evalLossCp, 5);
      expect(e6.positionEvalCp, -15);
      expect(e6.bestMoveEvalCp, -20);
      expect(e6.movePath, ['e4']);
      expect(e6.cumulativeProbability, 0.5);
      expect(warnings, isEmpty);
    });

    test('an engine failure is one warning, not an exception', () async {
      final found = await finder(
        _quiet.copyWith(useStockfish: true),
      ).missingReplies(afterE4());

      expect(found, isEmpty);
      expect(warnings, ['Stockfish could not check some opponent replies.']);
    });
  });

  group('ChessDB source', () {
    test('stores White-POV evals and is critical only when sharp', () async {
      final db = _ScriptedDb({
        afterE4().fen: const [
          DbMove(uci: 'e7e5', san: 'e5', stmCp: 20),
          DbMove(uci: 'e7e6', san: 'e6', stmCp: 12),
          DbMove(uci: 'g8f6', san: 'Nf6', stmCp: -20),
        ],
      });

      final found = await finder(
        _quiet.copyWith(useChessDb: true, strongReplyWindowCp: 50),
        db: db,
      ).missingReplies(afterE4());

      expect(found.map((f) => f.missingMove), ['e6', 'Nf6']);
      final e6 = found.first;
      expect(e6.source, MissingResponseSource.chessDb);
      expect(e6.severity, AuditSeverity.critical, reason: '8cp gap, 3 good');
      expect(e6.evalLossCp, 8);
      expect(e6.positionEvalCp, -12, reason: 'Black +12 is White -12');
      expect(e6.bestMoveEvalCp, -20);
      expect(e6.continuationCount, 3);
      expect(found.last.severity, AuditSeverity.warning);
    });

    test('is not consulted when off, and an empty answer warns', () async {
      final db = _ScriptedDb({});

      final off = await finder(_quiet, db: db).missingReplies(afterE4());
      expect(off, isEmpty);
      expect(db.calls, isEmpty);

      final on = await finder(
        _quiet.copyWith(useChessDb: true),
        db: db,
      ).missingReplies(afterE4());
      expect(on, isEmpty);
      expect(db.calls, [afterE4().fen]);
      expect(warnings.single, startsWith('ChessDB had no scored replies'));
    });
  });

  test('the first source to name a move owns it', () async {
    final db = _ScriptedDb({
      afterE4().fen: const [
        DbMove(uci: 'e7e5', san: 'e5', stmCp: 20),
        DbMove(uci: 'e7e6', san: 'e6', stmCp: 20),
      ],
    });
    scriptEngineAfterE4([
      (-20, 'e7e5'),
      (-20, 'e7e6'), // ChessDB already has it
      (-20, 'g8f6'), // new
    ]);

    final found = await finder(
      _quiet.copyWith(useChessDb: true, useStockfish: true),
      db: db,
    ).missingReplies(afterE4());

    expect(found.map((f) => (f.missingMove, f.source)), [
      ('e6', MissingResponseSource.chessDb),
      ('Nf6', MissingResponseSource.engine),
    ]);
  });

  group('clash tree', () {
    test('flags the book\'s replies with their play share', () async {
      final found = await finder(
        _quiet,
        clashTree: await _build(_clashGames),
      ).missingReplies(afterE4());

      expect(found, hasLength(1));
      final e6 = found.single;
      expect(e6.missingMove, 'e6');
      expect(e6.source, MissingResponseSource.clash);
      expect(e6.gameCount, 2);
      expect(e6.probability, closeTo(2 / 3, 1e-9));
      expect(e6.cumulativeProbability, closeTo(0.5 * 2 / 3, 1e-9));
      expect(e6.severity, AuditSeverity.critical);
    });

    test('a clash reply that transposes into the file says so', () async {
      // After 1.Nf3 Nc6 2.e4 the file plays only 2...d6; the book's 2...e5
      // lands on the 1.e4 e5 2.Nf3 Nc6 position the file does have, its
      // 2...g6 on one it does not.
      tree = await _build(const [
        '[Result "*"]\n\n1. e4 e5 2. Nf3 Nc6 *',
        '[Result "*"]\n\n1. Nf3 Nc6 2. e4 d6 *',
      ]);
      final clashTree = await _build(const [
        '[Result "*"]\n\n1. Nf3 Nc6 2. e4 e5 *',
        '[Result "*"]\n\n1. Nf3 Nc6 2. e4 g6 *',
      ]);
      final entry = RepertoireWalkEntry(
        node: tree.root.children['Nf3']!.children['Nc6']!.children['e4']!,
        movePath: const ['Nf3', 'Nc6', 'e4'],
        ply: 3,
        cumulativeProbability: 1.0,
      );

      final found = await finder(
        _quiet,
        clashTree: clashTree,
      ).missingReplies(entry);

      final bySan = {for (final f in found) f.missingMove: f};
      expect(bySan.keys, unorderedEquals(['e5', 'g6']));
      expect(bySan['e5']!.transposesIntoRepertoire, isTrue);
      expect(bySan['g6']!.transposesIntoRepertoire, isFalse);
    });
  });

  group('continuationsAt', () {
    test('stops asking once enough continuations are known', () async {
      final db = _ScriptedDb({
        afterE4().fen: const [
          DbMove(uci: 'e7e5', san: 'e5', stmCp: 20),
          DbMove(uci: 'c7c5', san: 'c5', stmCp: 15),
        ],
      });

      final moves = await finder(
        _quiet.copyWith(useChessDb: true, deadEndMinContinuations: 2),
        db: db,
      ).continuationsAt(afterE4());

      expect(moves, {'e5', 'c5'});
      expect(db.calls, hasLength(1));
    });

    test('with every source off there is nothing to count', () async {
      expect(await finder(_quiet).continuationsAt(afterE4()), isEmpty);
    });
  });
}

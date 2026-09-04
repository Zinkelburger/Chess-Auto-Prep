/// Headless `BuildMode.chessDbBook` run, from the command line.
///
/// Sibling of `master_build_overnight.dart` — same sandbox trick, different
/// pipeline: no Maia (this mode never asks it anything) and the moves come
/// from ChessDB rather than from a MultiPV sweep, so the engine only spins up
/// for positions ChessDB has never seen.  Named without a `_test` suffix so a
/// bare `flutter test` (and CI) never runs it.
///
/// The whole export path runs too — extraction, pruning, ECO chapters, model
/// games — because the point is a repertoire file to open, not a node count.
///
///   flutter test test/benchmark/chessdb_book_build.dart \
///     --dart-define=OUT=/tmp/run --dart-define=DB=…/master_games.db \
///     --dart-define=NAME="King's Indian (ChessDB)" \
///     --dart-define=START_MOVES="d4 Nf6 c4 g6 Nc3 Bg7 e4 d6" \
///     --dart-define=PLAY_WHITE=false
library;

import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/course/chapter_titles.dart';
import 'package:chess_auto_prep/services/generation/course/course_composer.dart';
import 'package:chess_auto_prep/services/generation/course/opening_namer.dart';
import 'package:chess_auto_prep/services/generation/course/model_game_selector.dart';
import 'package:chess_auto_prep/services/generation/eca_calculator.dart';
import 'package:chess_auto_prep/services/generation/fen_map.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/generation/line_extractor.dart';
import 'package:chess_auto_prep/services/generation/line_pruner.dart';
import 'package:chess_auto_prep/services/generation/repertoire_selector.dart';
import 'package:chess_auto_prep/services/generation/tree_ease.dart';
import 'package:chess_auto_prep/services/generation/tree_my_ease.dart';
import 'package:chess_auto_prep/services/generation/tree_serialization.dart';
import 'package:chess_auto_prep/services/master_games/master_games_db.dart';
import 'package:chess_auto_prep/services/master_games/master_model_games.dart';
import 'package:chess_auto_prep/services/opening_book_service.dart';
import 'package:chess_auto_prep/services/tree_build_service.dart';
import 'package:chess_auto_prep/utils/chess_utils.dart' show fenAfterMoves;
import 'package:chess_auto_prep/utils/fen_utils.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _out = String.fromEnvironment('OUT');
const _db = String.fromEnvironment('DB');
const _name = String.fromEnvironment('NAME', defaultValue: 'ChessDB book');

/// Where to write the repertoire folder; empty = only the OUT sandbox.
const _repertoiresDir = String.fromEnvironment('REPERTOIRES_DIR');

const _startMoves = String.fromEnvironment('START_MOVES', defaultValue: '');
const _playAsWhite = bool.fromEnvironment('PLAY_WHITE', defaultValue: true);

/// Branching depth, in plies from the build root.  Past this the book follows
/// one line — it does not stop.
const _maxPly = int.fromEnvironment('MAX_PLY', defaultValue: 20);
const _tailPly = int.fromEnvironment('TAIL_PLY', defaultValue: 34);
const _maxNodes = int.fromEnvironment('MAX_NODES', defaultValue: 12000);
const _budgetMin = int.fromEnvironment('BUDGET_MIN', defaultValue: 120);

/// Stockfish depth for positions no ChessDB source knows.
const _evalDepth = int.fromEnvironment('EVAL_DEPTH', defaultValue: 30);
const _threads = int.fromEnvironment('THREADS', defaultValue: 8);

const _quota = int.fromEnvironment('API_QUOTA', defaultValue: 5000);

/// 1 on purpose: chessdb.cn serves steady one-at-a-time traffic indefinitely
/// and throttles bursts, and a throttled lookup costs an engine search.
const _apiConcurrency = int.fromEnvironment('API_CONCURRENCY', defaultValue: 1);

const _minEvalCp = int.fromEnvironment('MIN_EVAL_CP', defaultValue: -250);
const _maxEvalCp = int.fromEnvironment('MAX_EVAL_CP', defaultValue: 500);
const _oppMaxChildren = int.fromEnvironment(
  'OPP_MAX_CHILDREN',
  defaultValue: 5,
);
const _modelGames = int.fromEnvironment('MODEL_GAMES', defaultValue: 6);

/// Re-export an existing `tree.json` instead of building: Phase 2 and 3 only,
/// no network at all.  The export path changes far more often than the search
/// does, and re-running a finished build to see an annotation fix would cost
/// its whole request budget again.
const _reexportTree = String.fromEnvironment('REEXPORT_TREE');

/// Prune the export down to about this many lines (0 = keep everything).
const _targetLines = int.fromEnvironment('TARGET_LINES', defaultValue: 0);
const _minLinesPerChapter = int.fromEnvironment(
  'MIN_LINES_PER_CHAPTER',
  defaultValue: 4,
);

class _SandboxPathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _SandboxPathProvider({required this.documents, required this.support});
  final String documents;
  final String support;

  @override
  Future<String?> getApplicationDocumentsPath() async => documents;

  @override
  Future<String?> getApplicationSupportPath() async => support;
}

String get _home => Platform.environment['HOME']!;
String get _realSupportPath =>
    p.join(_home, '.local', 'share', 'com.example.chess_auto_prep');

void _say(String s) {
  stdout.writeln('[cdb] ${DateTime.now().toIso8601String()} $s');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;

    // Let the run reach the network. `TestWidgetsFlutterBinding` installs an
    // HttpOverrides mock that answers *every* request with an empty HTTP 400
    // — sensible for widget tests, invisible and fatal here: ChessDB reads
    // as a total miss at every position, the engine fallback quietly writes
    // the whole book, and the only symptom is that it takes hours. The
    // binding is still needed for rootBundle (the ECO book is an asset), so
    // clear the override rather than skip the binding.
    HttpOverrides.global = null;

    // A sandboxed quota counter: this run gets its own 5k rather than eating
    // into whatever the app has already spent today.
    SharedPreferences.setMockInitialValues({});
  });

  test('build a ChessDB mainline book', () async {
    if (_out.isEmpty) fail('OUT dart-define is required');
    if (_db.isEmpty) fail('DB dart-define is required');

    final outDir = Directory(_out)..createSync(recursive: true);
    final support = Directory(p.join(outDir.path, 'support'))
      ..createSync(recursive: true);
    final docs = Directory(p.join(outDir.path, 'docs'))
      ..createSync(recursive: true);

    final realBinary = File(p.join(_realSupportPath, 'stockfish-linux'));
    if (!realBinary.existsSync()) {
      fail('Stockfish binary not found at ${realBinary.path}');
    }
    final link = Link(p.join(support.path, 'stockfish-linux'));
    if (!link.existsSync()) link.createSync(realBinary.path);
    PathProviderPlatform.instance = _SandboxPathProvider(
      documents: docs.path,
      support: support.path,
    );

    final book = MasterGamesDb.open(_db, readOnly: true);
    final dbStats = book.stats();
    _say('master book: ${dbStats.games} games, ${dbStats.issues} issues');
    if (dbStats.games == 0) fail('master database is empty — download first');

    final sans = _startMoves.trim().isEmpty
        ? const <String>[]
        : _startMoves.trim().split(RegExp(r'\s+'));
    final startFen = sans.isEmpty
        ? kStandardStartFen
        : fenAfterMoves(kStandardStartFen, sans, sans.length - 1);

    final config = TreeBuildConfig(
      startFen: startFen,
      playAsWhite: _playAsWhite,
      buildMode: BuildMode.chessDbBook,
      selectionMode: SelectionMode.engineOnly,
      // Best-first: an anytime search, so a quota that runs out has already
      // been spent on the lines most likely to be reached.
      searchAlgorithm: SearchAlgorithm.fast,
      maxPly: _maxPly,
      bookTailMaxPly: _tailPly,
      maxNodes: _maxNodes,
      timeBudgetMinutes: _budgetMin,
      evalDepth: _evalDepth,
      engineThreads: _threads,
      // Wide: a book that plays the objectively best move has no reason to
      // stop following a line just because one side stands better.
      relativeEval: true,
      minEvalCp: _minEvalCp,
      maxEvalCp: _maxEvalCp,
      oppMaxChildren: _oppMaxChildren,
      oppMassTarget: 0.90,
      verifyFinal: false,
      useMasterGames: true,
      downloadMasterGamesIfMissing: false,
      enableChessDbApi: true,
      chessDbApiDailyQuota: _quota,
      chessDbApiConcurrency: _apiConcurrency,
      enableCdbDirect: false,
      enableLocalChessDb: false,
      organizeIntoChapters: true,
      chaptersByEco: true,
      minLinesPerChapter: _minLinesPerChapter,
      modelGameCount: _modelGames,
    );
    _say('root after "${sans.join(' ')}" = $startFen');
    _say('config ${jsonEncode(config.toJson())}');
    final rootBook = book.bookMoves(startFen);
    _say(
      'book at root: ${rootBook.length} moves '
      '${rootBook.take(6).map((m) => '${m.uci}(${m.games})').join(' ')}',
    );

    final BuildTree tree;
    if (_reexportTree.isNotEmpty) {
      _say('re-exporting $_reexportTree (no build, no network)');
      tree = deserializeTree(File(_reexportTree).readAsStringSync());
      _say('loaded ${tree.totalNodes} nodes, maxPly ${tree.maxPlyReached}');
    } else {
      tree = await _buildTree(config, book);
    }

    // Phase 2, exactly as GenerationSessionController._analyzeTreePhase.
    // Trivial here — one child per our-move node — but selection is what
    // marks the moves extraction reads.
    final anchored = config.anchoredToRoot(tree.root);
    _say(
      'eval window: [${config.minEvalCp}, ${config.maxEvalCp}] → '
      '[${anchored.minEvalCp}, ${anchored.maxEvalCp}] '
      '(root eval for us ${tree.root.evalForUs(config.playAsWhite)}cp)',
    );
    calculateTreeEase(tree);
    final fenMap = FenMap()..populate(tree.root);
    final eca = ExpectimaxCalculator(config: anchored, fenMap: fenMap);
    eca.calculate(tree);
    calculateMyEase(tree, playAsWhite: anchored.playAsWhite);
    final selected = RepertoireSelector(
      config: anchored,
      ecaCalc: eca,
      fenMap: fenMap,
    ).select(tree);
    _say('phase2: $selected repertoire moves selected');

    // Phase 3: extract, prune, compose.
    final extractor = LineExtractor(config: anchored, fenMap: fenMap);
    final raw = extractor.extract(tree);
    final slice = LinePruner.rank(raw);
    final lines = (_targetLines > 0 ? slice.take(_targetLines) : slice.all)
      ..sort((a, b) => b.probability.compareTo(a.probability));
    _say('phase3: ${raw.length} lines extracted, ${lines.length} kept');

    final namer = CourseNamer(
      namer: OpeningNamer(
        book: await OpeningBookService.instance.load(),
        startFen: startFen,
      ),
      rootWhiteToMove: isWhiteToMove(startFen),
      startMoveNumber: fullMoveNumber(startFen),
      // The build root *is* the repertoire root here, so lines need no
      // prefix — the PGN carries a [FEN] header instead.
      repertoirePrefix: const [],
      playAsWhite: _playAsWhite,
    );
    final modelGames = _modelGames <= 0
        ? const <ModelGame>[]
        : const ModelGameSelector(playAsWhite: _playAsWhite).select(
            masterGameCandidates(
              book,
              tree,
              playAsWhite: _playAsWhite,
              minElo: anchored.modelGameMinElo,
            ),
            tree,
            limit: _modelGames,
            fenMap: fenMap,
          );
    final course = CourseComposer(
      config: anchored,
      namer: namer,
      repertoireStartFen: startFen,
      repertoirePrefix: const [],
      repertoireName: _name,
    ).compose(lines: lines, modelGames: modelGames);

    _say(
      'course: ${course.lineChapterCount} chapters, '
      '${course.modelGameCount} model games',
    );
    for (final chapter in course.outline) {
      _say('  ${chapter.name} — ${chapter.entryCount}');
    }

    final pgn = course.toPgn();
    File(p.join(outDir.path, 'Main.pgn')).writeAsStringSync(pgn);
    if (_reexportTree.isEmpty) {
      File(
        p.join(outDir.path, 'tree.json'),
      ).writeAsStringSync(serializeTree(tree));
    }

    if (_repertoiresDir.isNotEmpty) {
      final dir = Directory(p.join(_repertoiresDir, _name))
        ..createSync(recursive: true);
      final file = File(p.join(dir.path, 'Main.pgn'));
      file.writeAsStringSync(pgn);
      _say('wrote ${file.path}');
      if (course.modelGamePgns.isNotEmpty) {
        File(
          p.join(dir.path, 'Model games.pgn'),
        ).writeAsStringSync(course.modelGamePgns.join('\n'));
      }
    }

    book.close();
    expect(lines, isNotEmpty);
  }, timeout: const Timeout(Duration(hours: 6)));
}

/// The Phase 1 build, factored out so [_reexportTree] can skip it entirely.
Future<BuildTree> _buildTree(TreeBuildConfig config, MasterGamesDb book) async {
  final service = TreeBuildService();
  var lastReport = 0;
  final wall = Stopwatch()..start();
  final tree = await service.build(
    config: config,
    isCancelled: () => false,
    masterBook: book.bookMoves,
    onProgress: (bp) {
      final now = wall.elapsedMilliseconds;
      if (now - lastReport < 30000) return;
      lastReport = now;
      final s = service.buildStats;
      _say(
        'progress ${(now / 60000).toStringAsFixed(1)}min '
        'nodes=${bp.totalNodes} maxPly=${bp.maxPlyReached} '
        'frontier=${bp.frontierSize} '
        'cdb=${s.bookDbMoveHits} sf=${s.bookEngineFallbacks} '
        'dead=${s.bookDeadEnds}',
      );
    },
  );
  wall.stop();
  final outDir = Directory(_out);
  File(p.join(outDir.path, 'run.log')).writeAsStringSync(service.runLog.dump());
  final s = service.buildStats;
  _say(
    'build done: ${tree.totalNodes} nodes, maxPly ${tree.maxPlyReached}, '
    'complete=${tree.buildComplete}, '
    '${(wall.elapsedMilliseconds / 60000).toStringAsFixed(1)}min',
  );
  _say(
    'sources: chessdb=${s.bookDbMoveHits} engine=${s.bookEngineFallbacks} '
    'dead-ends=${s.bookDeadEnds} '
    'api(hits=${s.chessDbApiHits} misses=${s.chessDbApiMisses} '
    'quota-blocked=${s.chessDbApiQuotaBlocked})',
  );
  File(
    p.join(outDir.path, 'stats.json'),
  ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(s.toJson()));
  return tree;
}

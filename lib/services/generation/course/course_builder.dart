/// Turning a finished build's extracted lines into the course document.
///
/// This is the second half of an export: the tree is built and the lines are
/// picked, and what remains is everything that makes them *readable* — the
/// four best-effort enrichment passes (refutations, engine tails, refuted
/// alternatives, master improvements), the opening names, the model games,
/// and the composition of all of it into chapters.
///
/// It lived inside `GenerationSessionController` as nine private methods and
/// four fields it wrote back into. Pulling it out is not cosmetic: this half
/// is the part with real branching worth testing on its own — which source
/// the model games come from, what happens when there is no database, what
/// the user is told when a pass finds nothing — and none of it needs a
/// running build, a notifier, or a file on disk.
///
/// Everything here degrades rather than fails. A missing opening book means
/// move-based chapter names; a build with no game database simply has no
/// model games; a cancelled or failed enrichment pass contributes nothing.
library;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../models/build_tree_node.dart';
import '../../../utils/fen_utils.dart';
import '../../master_games/master_games_db.dart';
import '../../master_games/master_model_games.dart';
import '../../engine/stockfish_pool.dart';
import '../../opening_book_service.dart';
import '../engine_tail.dart';
import '../fen_map.dart';
import '../generation_config.dart';
import '../line_extractor.dart';
import '../line_pruner.dart';
import '../pgn_freq_map.dart' show PgnFreqMap, PgnGameRecord;
import 'chapter_titles.dart';
import 'course_composer.dart';
import 'enrichment_runner.dart';
import 'master_improvements.dart';
import 'model_game_selector.dart';
import 'opening_namer.dart';
import 'refutation_prober.dart';

/// A composed course and the one thing about it the run summary has to say
/// that the document itself cannot: why there are no model games.
///
/// Returned rather than written back into the caller's fields, so the passes
/// below have no reason to reach outward and the whole build is a value a
/// test can assert on.
class CourseBuild {
  const CourseBuild({required this.course, required this.modelGameNote});

  final ComposedCourse course;

  /// Empty when the course has model games, or was never asked for any.
  /// Otherwise a sentence naming what was searched and came up empty —
  /// an empty trailing section is otherwise indistinguishable from the
  /// feature being switched off.
  final String modelGameNote;
}

/// Composes the course for one export.
///
/// Stateless between calls: [build] takes everything it needs and returns
/// everything it produced. The suppliers exist because the values behind them
/// are reassigned by the owner between runs — a new game database is loaded
/// per build, the master-games service finishes loading after construction —
/// and a cached reference would quietly serve the previous run's data.
class CourseBuilder {
  CourseBuilder({
    required this.enrichment,
    required this.gameDatabase,
    required this.masterDbFor,
    required this.fenMap,
  });

  /// Runs the four optional passes and keeps their counts; shared with the
  /// owner, which reports those counts in the run summary.
  final EnrichmentRunner enrichment;

  /// The build's own game database, when it loaded one. Reassigned per run.
  final PgnFreqMap? Function() gameDatabase;

  /// The master-games database for a config, or null when it is switched off
  /// or the service has no games. Finishes loading after construction.
  final MasterGamesDb? Function(TreeBuildConfig config) masterDbFor;

  /// The finished tree's FEN index, used to test whether a candidate game
  /// actually follows the repertoire. Null until the tree is built.
  final FenMap? Function() fenMap;

  /// Companion file path for a course at [courseFilePath] — the model games
  /// again, as a game collection a PGN viewer opens directly.
  static String modelGamesPathFor(String courseFilePath) => p.join(
    p.dirname(courseFilePath),
    '${p.basenameWithoutExtension(courseFilePath)}_model_games.pgn',
  );

  /// Enrich [lines] and compose them into a course.
  ///
  /// The four passes run in sequence rather than concurrently: each drives
  /// the same shared engine pool, and interleaving them would only make the
  /// progress line lie about which one is running.
  Future<CourseBuild> build({
    required BuildTree tree,
    required List<ExtractedLine> lines,
    required TreeBuildConfig config,
    Map<String, List<FoldedLine>> folds = const {},
    required String repertoireFilePath,
    required String rootFen,
    required List<String> prefix,
  }) async {
    final refutations = await _refutations(lines, config);
    final alternatives = await _alternatives(lines, config);
    final tails = await _engineTails(lines, config);
    final improvements = await _improvements(lines, config);

    final (models, note) = _selectModelGames(tree, config, improvements);

    final namer = CourseNamer(
      namer: await _loadOpeningNamer(rootFen),
      rootWhiteToMove: isWhiteToMove(rootFen),
      startMoveNumber: fullMoveNumber(rootFen),
      repertoirePrefix: prefix,
      playAsWhite: config.playAsWhite,
    );

    final course =
        CourseComposer(
          config: config,
          namer: namer,
          repertoireStartFen: rootFen,
          repertoirePrefix: prefix,
          repertoireName: p.basenameWithoutExtension(repertoireFilePath),
        ).compose(
          lines: lines,
          folds: folds,
          modelGames: models,
          refutations: refutations,
          alternatives: alternatives,
          engineTails: tails,
          improvements: improvements,
        );

    return CourseBuild(course: course, modelGameNote: note);
  }

  // ── The four enrichment passes ──────────────────────────────────────────

  /// Ask the engine how the replies that end a line in a won position are
  /// actually punished, so those lines stop dead on the opponent's mistake.
  Future<RefutationMap> _refutations(
    List<ExtractedLine> lines,
    TreeBuildConfig config,
  ) => enrichment.run<List<String>>(
    EnrichmentPass.refutations,
    enabled: config.refutationLines,
    status: (done, total) =>
        'Phase 3.5: Showing how losing replies are punished '
        '($done of $total)...',
    prepare: () {
      final prober = RefutationProber(config: config);
      if (prober.targets(lines).isEmpty) return null;
      return ({required isCancelled, required onProgress}) =>
          prober.probe(lines, isCancelled: isCancelled, onProgress: onProgress);
    },
  );

  /// Ask what a human would play at each position the export passes through
  /// that the book leaves out, and why it is left out.
  Future<AlternativeMap> _alternatives(
    List<ExtractedLine> lines,
    TreeBuildConfig config,
  ) => enrichment.run<RefutedAlternative>(
    EnrichmentPass.alternatives,
    enabled: config.alternativeLines,
    status: (done, total) =>
        'Phase 3.6: Checking the moves the book leaves out '
        '($done of $total positions)...',
    prepare: () {
      final prober = RefutationProber(
        config: config,
        freqMap: gameDatabase(),
        masterBook: masterDbFor(config)?.bookMoves,
      );
      if (prober.alternativeSites(lines).isEmpty) return null;
      return ({required isCancelled, required onProgress}) =>
          prober.probeAlternatives(
            lines,
            isCancelled: isCancelled,
            onProgress: onProgress,
          );
    },
  );

  /// Extend lines that stop at the build's ply cap with a few plies of raw
  /// engine play, so a truncated line ends somewhere a reader can see.
  ///
  /// Emitted as a sideline off the final move rather than appended to it, for
  /// the same reason refutations are: the mainline is what training quizzes,
  /// and these moves carry none of the vetting the prepared moves do. They
  /// are a look over the edge, not repertoire.
  Future<Map<String, EngineTail>> _engineTails(
    List<ExtractedLine> lines,
    TreeBuildConfig config,
  ) => enrichment.run<EngineTail>(
    EnrichmentPass.engineTails,
    enabled: config.engineTailPlies > 0,
    status: (done, total) =>
        'Phase 3.7: Extending cut-off lines with engine play '
        '($done of $total) at depth ${config.resolvedEngineTailDepth}...',
    prepare: () =>
        ({required isCancelled, required onProgress}) => computeEngineTails(
          lines: lines,
          config: config,
          pool: StockfishPool.instance,
          isCancelled: isCancelled,
          onProgress: onProgress,
        ),
  );

  /// Where the repertoire departs from what masters play and the engine backs
  /// the departure, cite the game it improves on. Skipped without the
  /// master-games database.
  Future<ImprovementMap> _improvements(
    List<ExtractedLine> lines,
    TreeBuildConfig config,
  ) => enrichment.run<MasterImprovement>(
    EnrichmentPass.improvements,
    enabled: true,
    status: (done, total) =>
        'Phase 3.8: Comparing with master practice '
        '($done of $total positions)...',
    prepare: () {
      final db = masterDbFor(config);
      if (db == null) return null;
      final prober = MasterImprovementProber(
        config: config,
        book: db.bookMoves,
        gameById: db.game,
      );
      if (prober.sites(lines).isEmpty) return null;
      return ({required isCancelled, required onProgress}) =>
          prober.probe(lines, isCancelled: isCancelled, onProgress: onProgress);
    },
  );

  // ── Model games and names ───────────────────────────────────────────────

  /// The model games, and the note explaining an empty result.
  ///
  /// Two sources, in order of preference: the build's own game database (the
  /// strongest games it already loaded), then the master-games database. The
  /// note says which one was searched, because "nothing in your database
  /// follows this repertoire" is something the user can act on and an empty
  /// section is not.
  (List<ModelGame>, String) _selectModelGames(
    BuildTree tree,
    TreeBuildConfig config,
    ImprovementMap improvements,
  ) {
    if (config.modelGameCount <= 0) return (const [], '');

    final database = gameDatabase();
    final Iterable<PgnGameRecord> candidates;
    final String sourceLabel;
    if (database != null && !database.games.isEmpty) {
      candidates = database.games.entries;
      sourceLabel =
          'the ${database.games.length} strongest games in the database';
    } else {
      final masterDb = masterDbFor(config);
      if (masterDb == null) {
        // Only worth saying when a database was part of the build; an
        // engine build never has one, and "no game database" would just be
        // noise.
        return (
          const [],
          config.buildMode == BuildMode.dbExplorer
              ? ' No model games: this build had no game database to draw '
                    'them from.'
              : '',
        );
      }
      candidates = masterGameCandidates(
        masterDb,
        tree,
        playAsWhite: config.playAsWhite,
        minElo: config.modelGameMinElo,
      );
      sourceLabel = 'the master games database';
    }

    final games = ModelGameSelector(playAsWhite: config.playAsWhite).select(
      candidates,
      tree,
      limit: config.modelGameCount,
      fenMap: fenMap(),
      improvedFens: improvements.keys.toSet(),
    );
    return (
      games,
      games.isEmpty
          ? ' No model games: nothing in $sourceLabel follows this repertoire.'
          : '',
    );
  }

  Future<OpeningNamer> _loadOpeningNamer(String rootFen) async {
    try {
      return OpeningNamer(
        book: await OpeningBookService.instance.load(),
        startFen: rootFen,
      );
    } catch (e) {
      debugPrint('[CourseBuilder] Opening book unavailable: $e');
      return OpeningNamer.unavailable(startFen: rootFen);
    }
  }
}

/// Clash one repertoire against one opponent's actual games.
///
/// This is orchestration, not new analysis: [RepertoireAuditService] already
/// walks a repertoire tree against a "clash tree" of foreign games and emits
/// the moves our book fails to answer. What tournament prep adds is pointing
/// that machinery at *one specific person's archive*, filtered to the color
/// they will hold against us.
///
/// The output is a ranked list of the positions we will actually reach against
/// this opponent, weighted by how often they play into them.
library;

import 'package:flutter/foundation.dart';

import '../../../models/opening_tree.dart';
import '../../../services/analysis_games_service.dart';
import '../../audit/models/audit_finding.dart';
import '../../audit/services/audit_config.dart';
import '../../audit/services/repertoire_audit_service.dart';
import '../models/roster_entry.dart';

/// Knobs for a single clash run.
class ClashConfig {
  /// How many of the opponent's games to pull. More games means a better
  /// frequency estimate and a slower run.
  final int maxGames;

  /// Only consider games from the last N months. Null keeps everything —
  /// but a repertoire from four years ago is weak evidence about today.
  final int? monthsBack;

  /// Minimum share of the opponent's games at a position for an uncovered
  /// move to be reported. Filters one-off experiments out of the report.
  final double minMoveShare;

  /// Plies from the repertoire root to walk.
  final int maxPly;

  /// Stockfish depth for move-quality checks. Only used when [useStockfish].
  final int evalDepth;

  /// Whether to also run the engine-backed mistake/weak-position checks.
  /// Off by default: a clash run is about coverage gaps, and the engine pass
  /// is far more expensive than the tree walk.
  final bool useStockfish;

  const ClashConfig({
    this.maxGames = 300,
    this.monthsBack = 24,
    this.minMoveShare = 0.05,
    this.maxPly = 24,
    this.evalDepth = 14,
    this.useStockfish = false,
  });

  Map<String, dynamic> toMap() => {
    'max_games': maxGames,
    if (monthsBack != null) 'months_back': monthsBack,
    'min_move_share': minMoveShare,
    'max_ply': maxPly,
    'eval_depth': evalDepth,
    'use_stockfish': useStockfish,
  };

  factory ClashConfig.fromMap(Map<String, dynamic> m) => ClashConfig(
    maxGames: (m['max_games'] as num?)?.toInt() ?? 300,
    monthsBack: (m['months_back'] as num?)?.toInt(),
    minMoveShare: (m['min_move_share'] as num?)?.toDouble() ?? 0.05,
    maxPly: (m['max_ply'] as num?)?.toInt() ?? 24,
    evalDepth: (m['eval_depth'] as num?)?.toInt() ?? 14,
    useStockfish: m['use_stockfish'] as bool? ?? false,
  );
}

/// One gap between our repertoire and an opponent's practice.
class ClashGap {
  /// SAN path from the repertoire root to the position.
  final List<String> movePath;
  final String fen;

  /// The opponent move our repertoire has no answer to.
  final String missingMove;

  /// How often they play it in this position (0–1).
  final double moveShare;

  /// Their games in this position that went down this move.
  final int gameCount;

  /// Probability of reaching this position at all, along the repertoire path.
  final double reachProbability;

  /// True when the move transposes back into something we do cover, which
  /// downgrades it from a hole to a move-order note.
  final bool transposes;

  final AuditSeverity severity;

  const ClashGap({
    required this.movePath,
    required this.fen,
    required this.missingMove,
    required this.moveShare,
    required this.gameCount,
    required this.reachProbability,
    required this.transposes,
    required this.severity,
  });

  /// Ranking score for a single opponent: how likely we are to actually face
  /// this position. The tournament-wide ranking multiplies this by P(pairing).
  double get weight => reachProbability * moveShare;

  String get line => movePath.isEmpty ? '(start)' : movePath.join(' ');

  Map<String, dynamic> toMap() => {
    'line': line,
    'move_path': movePath,
    'fen': fen,
    'missing_move': missingMove,
    'move_share': moveShare,
    'game_count': gameCount,
    'reach_probability': reachProbability,
    'weight': weight,
    'transposes': transposes,
    'severity': severity.name,
  };
}

/// Everything one clash run produced.
class ClashReport {
  final String playerId;
  final String playerName;
  final String username;
  final String platform;

  /// True when the repertoire clashed was our White one.
  final bool weAreWhite;

  /// Gaps, ranked by [ClashGap.weight] descending.
  final List<ClashGap> gaps;

  /// Opponent games that fed the clash tree, after color filtering.
  final int gamesAnalyzed;

  final Duration elapsed;

  /// Non-fatal problems: no games found, download failed, archive too thin.
  final List<String> warnings;

  const ClashReport({
    required this.playerId,
    required this.playerName,
    required this.username,
    required this.platform,
    required this.weAreWhite,
    required this.gaps,
    required this.gamesAnalyzed,
    required this.elapsed,
    this.warnings = const [],
  });

  bool get isEmpty => gaps.isEmpty;

  Map<String, dynamic> toMap() => {
    'player_id': playerId,
    'player_name': playerName,
    'username': username,
    'platform': platform,
    'we_are_white': weAreWhite,
    'games_analyzed': gamesAnalyzed,
    'elapsed_ms': elapsed.inMilliseconds,
    'gaps': gaps.map((g) => g.toMap()).toList(),
    if (warnings.isNotEmpty) 'warnings': warnings,
  };
}

/// Progress ticks during a clash run.
class ClashProgress {
  final String stage;
  final String detail;
  final double? fraction;

  const ClashProgress(this.stage, this.detail, {this.fraction});
}

class ClashService {
  final AnalysisGamesService _games;
  final RepertoireAuditService _audit;

  ClashService({AnalysisGamesService? games, RepertoireAuditService? audit})
    : _games = games ?? AnalysisGamesService(),
      _audit = audit ?? RepertoireAuditService();

  void cancel() => _audit.cancel();

  /// Clash [repertoire] against [opponent]'s games.
  ///
  /// [weAreWhite] selects which of our repertoires is being tested, and
  /// therefore which color the opponent's games are filtered to — if we hold
  /// White, only their games as Black are evidence.
  Future<ClashReport> run({
    required RosterEntry opponent,
    required OpeningTree repertoire,
    required bool weAreWhite,
    ClashConfig config = const ClashConfig(),
    void Function(ClashProgress)? onProgress,
  }) async {
    final stopwatch = Stopwatch()..start();
    final warnings = <String>[];

    final username = opponent.preferredUsername;
    final platform = opponent.preferredPlatform;
    if (username == null || platform == null) {
      return ClashReport(
        playerId: opponent.id,
        playerName: opponent.name,
        username: '',
        platform: '',
        weAreWhite: weAreWhite,
        gaps: const [],
        gamesAnalyzed: 0,
        elapsed: stopwatch.elapsed,
        warnings: const [
          'No online account resolved for this entrant — nothing to clash '
              'against. Resolve an identity first.',
        ],
      );
    }

    onProgress?.call(
      ClashProgress('games', 'Fetching $username on $platform…'),
    );

    final pgnPath = await _ensureGames(
      platform: platform,
      username: username,
      config: config,
      warnings: warnings,
      onProgress: onProgress,
    );

    if (pgnPath == null) {
      return ClashReport(
        playerId: opponent.id,
        playerName: opponent.name,
        username: username,
        platform: platform,
        weAreWhite: weAreWhite,
        gaps: const [],
        gamesAnalyzed: 0,
        elapsed: stopwatch.elapsed,
        warnings: warnings,
      );
    }

    onProgress?.call(
      ClashProgress('clash', 'Walking repertoire against $username…'),
    );

    final result = await _audit.audit(
      tree: repertoire,
      isWhiteRepertoire: weAreWhite,
      config: AuditConfig(
        clashPgnPaths: [pgnPath],
        clashUsername: username,
        // They answer our repertoire with the opposite color.
        clashUserIsWhite: !weAreWhite,
        maxPly: config.maxPly,
        evalDepth: config.evalDepth,
        useStockfish: config.useStockfish,
        // The opponent's own archive is the evidence here; generic databases
        // would drown their individual tendencies in population averages.
        useLichessDb: false,
        useMaia: false,
      ),
      onProgress: (p) => onProgress?.call(
        ClashProgress(
          'clash',
          '${p.nodesChecked}/${p.totalNodes} positions',
          fraction: p.totalNodes == 0 ? null : p.nodesChecked / p.totalNodes,
        ),
      ),
    );

    final gaps =
        result.findings
            .where(
              (f) =>
                  f.type == AuditFindingType.missingResponse &&
                  f.source == MissingResponseSource.clash &&
                  (f.probability ?? 0) >= config.minMoveShare,
            )
            .map(
              (f) => ClashGap(
                movePath: f.movePath,
                fen: f.fen,
                missingMove: f.missingMove ?? '',
                moveShare: f.probability ?? 0,
                gameCount: f.gameCount ?? 0,
                reachProbability: f.cumulativeProbability ?? 0,
                transposes: f.transposesIntoRepertoire,
                severity: f.severity,
              ),
            )
            .toList()
          ..sort((a, b) => b.weight.compareTo(a.weight));

    if (gaps.isEmpty) {
      warnings.add(
        'No uncovered moves found for $username above a '
        '${(config.minMoveShare * 100).round()}% play rate. Either the '
        'repertoire already covers them or their archive is too thin.',
      );
    }

    return ClashReport(
      playerId: opponent.id,
      playerName: opponent.name,
      username: username,
      platform: platform,
      weAreWhite: weAreWhite,
      gaps: gaps,
      gamesAnalyzed: result.nodesChecked,
      elapsed: stopwatch.elapsed,
      warnings: warnings,
    );
  }

  /// Ensure the opponent's games are on disk, downloading if needed.
  /// Returns the PGN path, or null when nothing could be fetched.
  Future<String?> _ensureGames({
    required String platform,
    required String username,
    required ClashConfig config,
    required List<String> warnings,
    void Function(ClashProgress)? onProgress,
  }) async {
    try {
      final existing = await _games.findExistingPlayer(platform, username);
      if (existing != null) {
        return _games.analysisPgnPath(platform, username);
      }

      final pgns = platform == 'lichess'
          ? await _games.downloadLichessGames(
              username,
              maxGames: config.maxGames,
              monthsBack: config.monthsBack,
              onProgress: (m) => onProgress?.call(ClashProgress('games', m)),
            )
          : await _games.downloadChesscomGames(
              username,
              maxGames: config.maxGames,
              monthsBack: config.monthsBack,
              onProgress: (m) => onProgress?.call(ClashProgress('games', m)),
            );

      if (pgns.trim().isEmpty) {
        warnings.add('No games found for $username on $platform.');
        return null;
      }

      await _games.saveAnalysisGames(
        pgns,
        platform: platform,
        username: username,
        maxGames: config.maxGames,
        monthsBack: config.monthsBack,
      );
      return _games.analysisPgnPath(platform, username);
    } catch (e) {
      if (kDebugMode) debugPrint('[Clash] game fetch failed for $username: $e');
      warnings.add('Could not fetch games for $username: $e');
      return null;
    }
  }
}

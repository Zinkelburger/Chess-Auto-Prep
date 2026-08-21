/// "12.Nf3 improves on 12.Bg5 in Aronian–So, Saint Louis 2026."
///
/// Where the repertoire plays a move that is *not* what titled players
/// usually play from the same position, and the engine says ours is clearly
/// better, the export says so and cites the game — a repertoire grounded in
/// master practice should show where it departs from it and why.
///
/// The master move comes from the local master-games book (most-played move
/// at the position), the verdict from one engine search after it, and the
/// citation from the strongest game that played it.  Capped and deduplicated
/// by position like the other post-build probes in `refutation_prober.dart`.
library;

import 'package:dartchess/dartchess.dart';

import '../../../utils/chess_utils.dart';
import '../../../utils/fen_utils.dart';
import '../../engine/stockfish_pool.dart';
import '../../eval/eval_canonicalize.dart';
import '../../master_games/master_games_db.dart';
import '../export/move_annotation.dart';
import '../generation_config.dart';
import '../line_extractor.dart';
import '../pgn_freq_parser.dart'
    show isResultToken, tokenToSan, tokenizeMovetext;

/// One departure from master practice, with the evidence for it.
class MasterImprovement {
  /// The repertoire move, as SAN from the position.
  final String ourSan;

  /// The most-played master move we improve on, as SAN.
  final String masterSan;

  /// Engine gain for us: eval after our move minus eval after [masterSan].
  final int gainCp;

  /// How many book games played [masterSan] here.
  final int masterGames;

  /// The cited game (strongest encounter with the master move).
  final MasterGame game;

  /// What the cited game played after [masterSan] — a few plies, so the
  /// reader sees the line the masters went down.
  final List<String> continuation;

  const MasterImprovement({
    required this.ourSan,
    required this.masterSan,
    required this.gainCp,
    required this.masterGames,
    required this.game,
    required this.continuation,
  });

  /// `½–½`, `1–0`, `0–1` or empty.
  String get resultSymbol => switch (game.result) {
    '1-0' => '1–0',
    '0-1' => '0–1',
    '1/2-1/2' => '½–½',
    _ => '',
  };

  /// The sentence attached to our move.
  String get note {
    final r = resultSymbol;
    final cite = r.isEmpty ? game.citation : '${game.citation}, $r';
    return '$ourSan improves on $masterSan ($cite)';
  }

  /// The sideline comment: where the master move came from.
  String get sidelineComment {
    final r = resultSymbol;
    final games = masterGames > 1 ? '; $masterGames master games' : '';
    return r.isEmpty ? '${game.citation}$games' : '${game.citation}, $r$games';
  }
}

/// Improvements keyed by [LineChoice.fenBefore].
typedef ImprovementMap = Map<String, MasterImprovement>;

class MasterImprovementProber {
  MasterImprovementProber({
    required this.config,
    required this.book,
    required this.gameById,
    StockfishPool? pool,
  }) : pool = pool ?? StockfishPool.instance;

  final TreeBuildConfig config;
  final BookLookup book;
  final MasterGame? Function(int id) gameById;
  final StockfishPool pool;

  /// Positions considered and searches spent (two per judged site), in
  /// export order — most important lines first.
  static const int maxSites = 200;
  static const int maxProbes = 80;

  /// Plies of the cited game shown after the master move.
  static const int continuationPlies = 6;

  /// Deepest ply of a cited game replayed to find the position.
  static const int maxReplayPlies = 60;

  /// Our-move positions in [lines] where the book knows the position.
  List<LineChoice> sites(List<ExtractedLine> lines) {
    final seen = <String>{};
    final out = <LineChoice>[];
    for (final line in lines) {
      for (final choice in line.choices) {
        if (!choice.isOurMove || choice.bestEvalCpForUs == null) continue;
        if (!seen.add(choice.fenBefore)) continue;
        out.add(choice);
        if (out.length >= maxSites) return out;
      }
    }
    return out;
  }

  /// Probe every site and return the improvements worth stating.
  ///
  /// Best-effort: an empty book position, an engine that is unavailable, a
  /// gain under [TreeBuildConfig.improvementMinGainCp] — each drops that
  /// one site and leaves the line as it was.
  Future<ImprovementMap> probe(
    List<ExtractedLine> lines, {
    bool Function()? isCancelled,
    void Function(int done, int total)? onProgress,
  }) async {
    if (pool.workerCount == 0) return const {};
    final ourUciAt = <String, String>{};
    for (final line in lines) {
      for (final choice in line.choices) {
        if (choice.isOurMove && choice.moveIndex < line.movesUci.length) {
          ourUciAt.putIfAbsent(
            choice.fenBefore,
            () => line.movesUci[choice.moveIndex],
          );
        }
      }
    }
    final targets = sites(lines);
    if (targets.isEmpty) return const {};

    final out = <String, MasterImprovement>{};
    var probesLeft = maxProbes;
    for (var i = 0; i < targets.length; i++) {
      if ((isCancelled?.call() ?? false) || probesLeft <= 0) break;
      final site = targets[i];
      final ourUci = ourUciAt[site.fenBefore];
      if (ourUci == null) continue;

      final master = _masterMoveOtherThan(site.fenBefore, ourUci);
      if (master != null) {
        probesLeft -= 2;
        final found = await _judge(site, ourUci, master);
        if (found != null) out[site.fenBefore] = found;
      }
      onProgress?.call(i + 1, targets.length);
    }
    return out;
  }

  /// The most-played book move at [fen] when it is not [ourUci]; null when
  /// the position is unknown or masters agree with us.
  BookMove? _masterMoveOtherThan(String fen, String ourUci) {
    final List<BookMove> moves;
    try {
      moves = book(fen);
    } catch (_) {
      return null;
    }
    if (moves.isEmpty) return null;
    final top = moves.first; // bookMoves() is sorted most-played first
    if (top.uci == ourUci || top.games <= 0) return null;
    return top;
  }

  Future<MasterImprovement?> _judge(
    LineChoice site,
    String ourUci,
    BookMove master,
  ) async {
    final afterMaster = playUciMove(site.fenBefore, master.uci);
    final afterOurs = playUciMove(site.fenBefore, ourUci);
    if (afterMaster == null || afterOurs == null) return null;

    // Both moves at the same depth: the build's eval of our move is shallow
    // and a deep probe of theirs alone would manufacture "improvements" out
    // of depth noise.
    final masterEvalForUs = await _evalForUs(afterMaster);
    if (masterEvalForUs == null) return null;
    final ourEvalForUs = await _evalForUs(afterOurs);
    if (ourEvalForUs == null) return null;
    final gain = ourEvalForUs - masterEvalForUs;
    if (gain < config.improvementMinGainCp) return null;

    // A citation is a claim about theory, so it wants the strongest
    // over-the-board classical game — [BookMove.citeGameId] — ahead of the
    // higher-rated blitz game `topGameId` so often points at in a TWIC
    // corpus that is more than half online play.
    final game =
        gameById(master.citeGameId) ??
        gameById(master.topGameId) ??
        gameById(master.recentGameId);
    if (game == null) return null;

    final ourSan = uciToSanOrNull(site.fenBefore, ourUci);
    if (ourSan == null) return null;
    final fromGame = _continuationFromGame(game, site.fenBefore, master.uci);
    final masterSan =
        fromGame?.$1 ?? uciToSanOrNull(site.fenBefore, master.uci);
    if (masterSan == null) return null;

    return MasterImprovement(
      ourSan: ourSan,
      masterSan: masterSan,
      gainCp: gain,
      masterGames: master.games,
      game: game,
      continuation: fromGame?.$2 ?? const [],
    );
  }

  /// One search from [fen]; eval from our perspective, or null when the
  /// engine could not deliver it (pool stopped, position rejected).
  Future<int?> _evalForUs(String fen) async {
    try {
      final r = await pool.discoverMoves(
        fen: fen,
        depth: config.resolvedVerifyDepth,
        multiPv: 1,
        isWhiteToMove: isWhiteToMove(fen),
      );
      if (r.lines.isEmpty) return null;
      final cpWhite = r.lines.first.effectiveCp;
      return config.playAsWhite ? cpWhite : -cpWhite;
    } catch (_) {
      return null;
    }
  }

  /// Replay [game] to [fen]; returns the SAN it played there (the master
  /// move) and the plies that followed, or null when the game reached the
  /// position by another route (or not at all) within [maxReplayPlies].
  (String, List<String>)? _continuationFromGame(
    MasterGame game,
    String fen,
    String masterUci,
  ) {
    final sans = <String>[];
    for (final t in tokenizeMovetext(game.movetext)) {
      if (isResultToken(t)) break;
      final san = tokenToSan(t);
      if (san != null) sans.add(san);
    }
    final target = canonicalizeFen4(fen);
    Position pos = Chess.initial;
    final limit = sans.length < maxReplayPlies ? sans.length : maxReplayPlies;
    for (var i = 0; i < limit; i++) {
      if (canonicalizeFen4(pos.fen) == target) {
        final Move? m;
        try {
          m = pos.parseSan(sans[i]);
        } catch (_) {
          return null;
        }
        if (m == null || m.uci != masterUci) return null;
        final end = i + 1 + continuationPlies;
        return (
          sans[i],
          sans.sublist(i + 1, end < sans.length ? end : sans.length),
        );
      }
      final Move? m;
      try {
        m = pos.parseSan(sans[i]);
      } catch (_) {
        return null;
      }
      if (m == null) return null;
      pos = pos.play(m);
    }
    return null;
  }
}

/// Improvements along [line], keyed by the index of the move of ours that
/// earns one.
///
/// Shared by the course composer and the snapshot export so both say the same
/// thing: an improvement the build found but the written PGN never mentions
/// is a note nobody reads.
Map<int, MasterImprovement> improvementsAlong(
  ExtractedLine line,
  ImprovementMap improvements,
) {
  if (improvements.isEmpty) return const {};
  final out = <int, MasterImprovement>{};
  for (final choice in line.choices) {
    if (!choice.isOurMove) continue;
    final found = improvements[choice.fenBefore];
    if (found != null) out[choice.moveIndex] = found;
  }
  return out;
}

/// [line]'s annotations with `improves on … in <game>` notes attached to the
/// moves that earned them.  Annotations are indexed by line move, so a line
/// shorter on annotations than on moves is padded.
List<MoveAnnotation> annotationsWithImprovements(
  ExtractedLine line,
  Map<int, MasterImprovement> along,
) {
  if (along.isEmpty) return line.moveAnnotations;
  final out = List<MoveAnnotation>.of(line.moveAnnotations);
  for (final entry in along.entries) {
    while (out.length <= entry.key) {
      out.add(MoveAnnotation.none);
    }
    out[entry.key] = out[entry.key].withNote(entry.value.note);
  }
  return out;
}

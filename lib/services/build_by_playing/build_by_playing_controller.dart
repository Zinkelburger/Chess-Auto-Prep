/// Interactive "Build by Playing" session.
///
/// The computer plays opponent moves by database popularity; the user answers
/// each uncovered position, exploring freely on a scratchpad board before
/// committing a move to the repertoire file.
///
/// Traversal: each line is played to its end (the opponent always plays its
/// most popular remaining reply), then the session backtracks to the deepest
/// unanswered opponent branch — most popular sibling first.
///
/// Position ownership: the session drives [RepertoireController] for all
/// *line* moves, so the PGN pane / Lines / Tree stay live. During scratchpad
/// exploration the repertoire cursor stays parked on the decision point and
/// the board renders the session-owned scratch tree instead. Nothing touches
/// the repertoire file except [commitMove], which goes through
/// [RepertoireWriter.addMoveAtPosition] (atomic, undoable).
library;

import 'dart:async';

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

import '../../core/repertoire_controller.dart';
import '../../features/browse/services/candidate_service.dart';
import '../../models/build_tree_node.dart';
import '../../models/explorer_response.dart';
import '../../models/move_tree.dart';
import '../../models/opening_tree.dart';
import '../../utils/fen_utils.dart';
import '../../utils/san_token_utils.dart';
import '../explorer_cache_service.dart';
import '../generation/fen_map.dart';
import 'build_by_playing_config.dart';

enum BuildByPlayingPhase {
  /// No session running.
  idle,

  /// Auto-playing covered repertoire answers / navigating to a popped branch.
  advancing,

  /// Fetching database stats and playing the opponent's reply.
  opponentThinking,

  /// Parked at a decision point — the user's turn, no repertoire answer yet.
  awaitingUserMove,

  /// The user is playing ephemeral scratchpad moves from the decision point.
  exploring,

  /// A commit is being written to the repertoire file.
  committing,

  /// Explorer failure, rate limit, or external navigation. [resume] recovers.
  paused,

  /// The pending-branch stack is empty — every line reached a cutoff.
  sessionComplete,
}

/// An opponent reply queued for later: when the current line ends, the
/// session backtracks here and plays [opponentSan].
class PendingBranch {
  const PendingBranch({
    required this.pathFromRoot,
    required this.opponentSan,
    required this.opponentUci,
    required this.probability,
    required this.cumulativeProbability,
    required this.games,
    required this.epdAfter,
  });

  /// SAN moves from the tree root to the opponent-to-move position.
  final List<String> pathFromRoot;

  /// The queued reply.
  final String opponentSan;
  final String opponentUci;

  /// Local play fraction of the reply at its position.
  final double probability;

  /// Product of opponent move probabilities, including this reply.
  final double cumulativeProbability;

  /// Games of this reply in the database.
  final int games;

  /// Normalised FEN after the reply — for transposition dedup.
  final String epdAfter;
}

/// Snapshot of the latest commit so it can be undone from the session.
class _CommitInfo {
  const _CommitInfo({
    required this.decisionPath,
    required this.decisionFen,
    required this.san,
    required this.cumProb,
  });

  final List<String> decisionPath;
  final String decisionFen;
  final String san;
  final double cumProb;
}

class BuildByPlayingController extends ChangeNotifier {
  BuildByPlayingController({
    required RepertoireController repertoire,
    ExplorerCacheService? explorer,
  })  // Private fields can't be named initializing formals.
      // ignore: prefer_initializing_formals
      : _repertoire = repertoire,
        _explorer = explorer ?? ExplorerCacheService.instance;

  final RepertoireController _repertoire;
  final ExplorerCacheService _explorer;

  // ── Session state ──────────────────────────────────────────────────

  BuildByPlayingPhase _phase = BuildByPlayingPhase.idle;
  BuildByPlayingPhase get phase => _phase;
  bool get isActive => _phase != BuildByPlayingPhase.idle;

  /// Invalidates in-flight async work when the session ends or restarts.
  int _epoch = 0;

  BuildByPlayingConfig _config = const BuildByPlayingConfig();
  BuildByPlayingConfig get config => _config;

  int _sessionRootLen = 0;
  double _cumProb = 1.0;
  final List<PendingBranch> _pendingBranches = [];
  final Set<String> _visitedOppEpds = {};

  /// Longest prefix of the current line known to be in the repertoire file;
  /// [_uncommittedSuffix] holds the plies played since (opponent replies and
  /// auto-played answers). Invariant while on the line:
  /// `_lastCommittedPath + _uncommittedSuffix == repertoire.currentMoveSequence`.
  List<String> _lastCommittedPath = [];
  List<String> _uncommittedSuffix = [];

  String? _decisionFen;
  List<String>? _decisionPath;
  String? get decisionFen => _decisionFen;

  String? _lastOpponentSan;
  String? _lastOpponentUci;
  String? get lastOpponentSan => _lastOpponentSan;
  String? get lastOpponentUci => _lastOpponentUci;

  int _lineNumber = 1;
  int _commitCount = 0;
  int get lineNumber => _lineNumber;
  int get commitCount => _commitCount;
  int get pendingBranchCount => _pendingBranches.length;

  String? _pauseMessage;
  bool _pausedFromDecision = false;

  _CommitInfo? _lastCommitInfo;
  bool get canUndoCommit =>
      _lastCommitInfo != null &&
      (_phase == BuildByPlayingPhase.awaitingUserMove ||
          _phase == BuildByPlayingPhase.exploring);

  // ── Candidates ─────────────────────────────────────────────────────

  CandidateService? _candidateService;
  List<CandidateMove> _candidates = [];
  bool _candidatesLoading = false;
  List<CandidateMove> get candidates => _candidates;
  bool get candidatesLoading => _candidatesLoading;

  // ── Scratchpad ─────────────────────────────────────────────────────

  MoveTree? _scratchTree;
  TreePath _scratchPath = TreePath.empty;

  /// SANs from the decision point to the scratch cursor.
  List<String> get scratchTrail =>
      _scratchTree?.sanSequenceAt(_scratchPath) ?? const [];

  /// First ply of the scratch cursor path — the move a scratch commit would
  /// save. Null when the cursor sits on the decision point itself.
  String? get scratchFirstMove {
    final trail = scratchTrail;
    return trail.isEmpty ? null : trail.first;
  }

  // ── Derived display state ──────────────────────────────────────────

  /// FEN the board should render: the scratch position while exploring,
  /// otherwise the repertoire cursor.
  String get boardFen => _phase == BuildByPlayingPhase.exploring
      ? _scratchTree!.fenAt(_scratchPath)
      : _repertoire.fen;

  String? get statusText {
    switch (_phase) {
      case BuildByPlayingPhase.idle:
        return null;
      case BuildByPlayingPhase.advancing:
        return 'Following existing repertoire moves…';
      case BuildByPlayingPhase.opponentThinking:
        return 'Opponent is choosing a reply…';
      case BuildByPlayingPhase.awaitingUserMove:
        return _lastOpponentSan != null
            ? 'Opponent played $_lastOpponentSan — your move'
            : 'Your move';
      case BuildByPlayingPhase.exploring:
        return 'Exploring — nothing is saved until you commit';
      case BuildByPlayingPhase.committing:
        return 'Saving move…';
      case BuildByPlayingPhase.paused:
        return _pauseMessage ?? 'Paused';
      case BuildByPlayingPhase.sessionComplete:
        return 'Session complete — $_commitCount '
            '${_commitCount == 1 ? 'move' : 'moves'} added';
    }
  }

  String get progressText =>
      'Line $_lineNumber · $pendingBranchCount '
      '${pendingBranchCount == 1 ? 'branch' : 'branches'} left';

  // ── Lifecycle ──────────────────────────────────────────────────────

  /// Begin a session. When [config.startFromCurrentPosition] is false, the
  /// board is first moved to the repertoire's root position.
  ///
  /// [generatedTree]/[fenMap] optionally enrich candidate rows with
  /// expectimax scores and trap badges from a prior generation run.
  Future<void> start(
    BuildByPlayingConfig config, {
    BuildTree? generatedTree,
    FenMap? fenMap,
  }) async {
    _resetSessionState();
    _config = config;
    _epoch++;
    _repertoire.addListener(_onRepertoireChanged);

    if (!config.startFromCurrentPosition) {
      _repertoire.navigateToLineMove(cleanSanTokens(_repertoire.rootMoves));
    }
    _sessionRootLen = _repertoire.currentMoveSequence.length;
    final (committed, suffix) =
        _splitByCoverage(_repertoire.currentMoveSequence);
    _lastCommittedPath = committed;
    _uncommittedSuffix = suffix;

    _candidateService = CandidateService(
      tree: generatedTree,
      fenMap: fenMap,
      openingTree: _repertoire.openingTree,
      explorerCache: _explorer,
      explorerSource: config.source,
    );

    _setPhase(BuildByPlayingPhase.advancing);
    await _advance();
  }

  /// Apply new knobs mid-session. Takes effect from the next opponent fetch
  /// / branch selection; already-queued branches are kept.
  void updateConfig(BuildByPlayingConfig config) {
    if (!isActive) return;
    _config = config;
    notifyListeners();
  }

  /// End the session. Committed moves are already saved; everything else
  /// (scratchpad, pending branches) is discarded.
  void endSession() {
    if (!isActive) return;
    _repertoire.removeListener(_onRepertoireChanged);
    _resetSessionState();
    _setPhase(BuildByPlayingPhase.idle);
  }

  void _resetSessionState() {
    if (isActive) _repertoire.removeListener(_onRepertoireChanged);
    _epoch++;
    _pendingBranches.clear();
    _visitedOppEpds.clear();
    _lastCommittedPath = [];
    _uncommittedSuffix = [];
    _decisionFen = null;
    _decisionPath = null;
    _lastOpponentSan = null;
    _lastOpponentUci = null;
    _lineNumber = 1;
    _commitCount = 0;
    _cumProb = 1.0;
    _pauseMessage = null;
    _pausedFromDecision = false;
    _lastCommitInfo = null;
    _candidateService = null;
    _candidates = [];
    _candidatesLoading = false;
    _scratchTree = null;
    _scratchPath = TreePath.empty;
  }

  @override
  void dispose() {
    endSession();
    super.dispose();
  }

  // ── Main loop ──────────────────────────────────────────────────────

  Future<void> _advance() async {
    final epoch = _epoch;
    while (true) {
      if (epoch != _epoch) return;

      final fen = _repertoire.fen;
      final pos = _positionFromFen(fen);
      final plyFromRoot =
          _repertoire.currentMoveSequence.length - _sessionRootLen;

      // Line-end cutoffs.
      if (pos == null ||
          pos.isGameOver ||
          plyFromRoot >= _config.maxPly ||
          _cumProb < _config.minCumulativeProbability) {
        if (!_popNextBranch()) return _completeSession();
        continue;
      }

      final ourTurn = isWhiteToMove(fen) == _repertoire.isRepertoireWhite;
      if (ourTurn) {
        final answer = _coveredAnswer(fen, pos);
        if (answer != null) {
          // Position already answered by the repertoire — follow it. Only
          // this ply is short-circuited; deeper uncovered positions in the
          // same branch are still reached.
          _setPhase(BuildByPlayingPhase.advancing);
          _repertoire.playMove(answer);
          _uncommittedSuffix.add(answer);
          continue;
        }
        // Decision point.
        _decisionFen = fen;
        _decisionPath = List.of(_repertoire.currentMoveSequence);
        _candidates = [];
        _candidatesLoading = true;
        _setPhase(BuildByPlayingPhase.awaitingUserMove);
        unawaited(_loadCandidates());
        return;
      }

      // Opponent's turn: fetch stats and play the most popular reply.
      _setPhase(BuildByPlayingPhase.opponentThinking);
      final resp = await _explorer.fetch(fen, _config.source);
      if (epoch != _epoch) return;

      if (resp == null) {
        _pause(
          _explorer.isRateLimited
              ? 'Lichess rate limit hit — wait a moment, then resume'
              : 'Opening database unavailable — check your connection, '
                  'then resume',
          fromDecision: false,
        );
        return;
      }
      if (resp.totalGames < _config.minGames) {
        if (!_popNextBranch()) return _completeSession();
        continue;
      }

      final replies = selectOpponentReplies(
        resp.moves,
        coverMinProb: _config.coverMinProb,
        oppMassTarget: _config.oppMassTarget,
        oppMaxChildren: _config.oppMaxChildren,
      );

      // Drop illegal SANs (defensive) and already-visited transpositions.
      final playable = <({ExplorerMove move, String epd, double cum})>[];
      for (final m in replies) {
        final parsed = pos.parseSan(m.san);
        if (parsed == null) continue;
        final epd = normalizeFen(pos.play(parsed).fen);
        if (_visitedOppEpds.contains(epd)) continue;
        playable.add((move: m, epd: epd, cum: _cumProb * m.playFraction));
      }
      if (playable.isEmpty) {
        if (!_popNextBranch()) return _completeSession();
        continue;
      }

      // Queue the non-primary replies, least popular first: the LIFO stack
      // then resumes at the deepest branch point, most popular sibling first.
      final basePath = List.of(_repertoire.currentMoveSequence);
      for (final r in playable.skip(1).toList().reversed) {
        if (r.cum < _config.minCumulativeProbability) continue;
        _pendingBranches.add(PendingBranch(
          pathFromRoot: basePath,
          opponentSan: r.move.san,
          opponentUci: r.move.uci,
          probability: r.move.playFraction,
          cumulativeProbability: r.cum,
          games: r.move.total,
          epdAfter: r.epd,
        ));
      }

      final first = playable.first;
      _visitedOppEpds.add(first.epd);
      _cumProb = first.cum;
      _lastOpponentSan = first.move.san;
      _lastOpponentUci = first.move.uci;
      _repertoire.playMove(first.move.san);
      _uncommittedSuffix.add(first.move.san);
    }
  }

  /// Pop the next pending branch and navigate there. Returns false when the
  /// stack is exhausted.
  bool _popNextBranch() {
    while (_pendingBranches.isNotEmpty) {
      final b = _pendingBranches.removeLast();
      // A transposition may have covered this reply since it was queued.
      if (_visitedOppEpds.contains(b.epdAfter)) continue;

      _lineNumber++;
      _lastCommitInfo = null;
      final full = [...b.pathFromRoot, b.opponentSan];
      _repertoire.navigateToLineMove(full);
      final (committed, suffix) = _splitByCoverage(full);
      _lastCommittedPath = committed;
      _uncommittedSuffix = suffix;
      _cumProb = b.cumulativeProbability;
      _visitedOppEpds.add(b.epdAfter);
      _lastOpponentSan = b.opponentSan;
      _lastOpponentUci = b.opponentUci;
      _setPhase(BuildByPlayingPhase.advancing);
      return true;
    }
    return false;
  }

  void _completeSession() {
    _decisionFen = null;
    _decisionPath = null;
    _scratchTree = null;
    _scratchPath = TreePath.empty;
    _setPhase(BuildByPlayingPhase.sessionComplete);
  }

  // ── Decision-point actions ─────────────────────────────────────────

  /// Route a board move by phase. At a decision point the move opens the
  /// scratchpad; while exploring it extends the scratch tree (both sides
  /// play freely). All other phases ignore input.
  void handleBoardMove(String san) {
    switch (_phase) {
      case BuildByPlayingPhase.awaitingUserMove:
        final tree = MoveTree(startingFen: _decisionFen!);
        final path = tree.addMove(TreePath.empty, san);
        if (path == null) return;
        _scratchTree = tree;
        _scratchPath = path;
        _setPhase(BuildByPlayingPhase.exploring);
      case BuildByPlayingPhase.exploring:
        final path = _scratchTree!.addMove(_scratchPath, san);
        if (path == null) return;
        _scratchPath = path;
        notifyListeners();
      default:
        return;
    }
  }

  /// Discard the scratchpad and return to the decision point.
  void backToDecisionPoint() {
    if (_phase != BuildByPlayingPhase.exploring) return;
    _scratchTree = null;
    _scratchPath = TreePath.empty;
    _setPhase(BuildByPlayingPhase.awaitingUserMove);
  }

  void scratchGoBack() {
    if (_phase != BuildByPlayingPhase.exploring) return;
    if (_scratchPath.isEmpty) return;
    _scratchPath = _scratchPath.parent;
    notifyListeners();
  }

  void scratchGoForward() {
    if (_phase != BuildByPlayingPhase.exploring) return;
    final next = _scratchPath.child(0);
    if (_scratchTree!.isValidPath(next)) {
      _scratchPath = next;
      notifyListeners();
    }
  }

  /// Jump the scratch cursor to ply [plyIndex] of the current trail
  /// (0 = first scratch move).
  void scratchJumpTo(int plyIndex) {
    if (_phase != BuildByPlayingPhase.exploring) return;
    final target = _scratchPath.take(plyIndex + 1);
    if (_scratchTree!.isValidPath(target)) {
      _scratchPath = target;
      notifyListeners();
    }
  }

  /// Commit the first scratch ply (see [scratchFirstMove]).
  Future<void> commitScratchFirstMove() async {
    final san = scratchFirstMove;
    if (san != null) await commitMove(san);
  }

  /// Commit [san] as the repertoire answer at the decision point: the
  /// uncommitted line prefix is written first (ply by ply, chaining paths so
  /// one session line stays one PGN game), then the move itself. The session
  /// then continues with the opponent's next reply.
  Future<void> commitMove(String san) async {
    if (_phase != BuildByPlayingPhase.awaitingUserMove &&
        _phase != BuildByPlayingPhase.exploring) {
      return;
    }
    final decisionFen = _decisionFen;
    final decisionPath = _decisionPath;
    if (decisionFen == null || decisionPath == null) return;
    final pos = _positionFromFen(decisionFen);
    if (pos == null || pos.parseSan(san) == null) return;

    _scratchTree = null;
    _scratchPath = TreePath.empty;
    _setPhase(BuildByPlayingPhase.committing);

    final epoch = _epoch;
    try {
      var path = List<String>.from(_lastCommittedPath);
      for (final ply in List<String>.from(_uncommittedSuffix)) {
        path = await _repertoire.writer.addMoveAtPosition(
          fen: _fenForSans(path),
          san: ply,
          pathFromRoot: path,
        );
      }
      path = await _repertoire.writer.addMoveAtPosition(
        fen: decisionFen,
        san: san,
        pathFromRoot: path,
      );
      if (epoch != _epoch) return;
      _lastCommittedPath = path;
      _uncommittedSuffix = [];
      _commitCount++;
      _lastCommitInfo = _CommitInfo(
        decisionPath: decisionPath,
        decisionFen: decisionFen,
        san: san,
        cumProb: _cumProb,
      );
    } catch (e) {
      if (epoch != _epoch) return;
      debugPrint('[BuildByPlaying] Commit failed: $e');
      _pause('Failed to save the move — resume to return to the decision '
          'point');
      return;
    }

    _decisionFen = null;
    _decisionPath = null;
    _repertoire.playMove(san);
    await _advance();
  }

  /// End the current line without committing an answer here. The position
  /// stays uncovered, so a later session will ask again.
  Future<void> skipDecision() async {
    if (_phase != BuildByPlayingPhase.awaitingUserMove &&
        _phase != BuildByPlayingPhase.exploring) {
      return;
    }
    _scratchTree = null;
    _scratchPath = TreePath.empty;
    _decisionFen = null;
    _decisionPath = null;
    if (!_popNextBranch()) return _completeSession();
    await _advance();
  }

  /// Undo the latest commit and re-park at its decision point. Pending
  /// branches that depended on the undone move are dropped so they cannot
  /// resurrect it.
  Future<bool> undoLastCommit() async {
    final info = _lastCommitInfo;
    if (info == null || !canUndoCommit) return false;

    _setPhase(BuildByPlayingPhase.committing); // suppress the nav guard
    final ok = await _repertoire.writer.undo();
    if (!ok) {
      _setPhase(BuildByPlayingPhase.awaitingUserMove);
      return false;
    }

    final stalePrefix = [...info.decisionPath, info.san];
    _pendingBranches
        .removeWhere((b) => _startsWith(b.pathFromRoot, stalePrefix));
    _lastCommitInfo = null;
    _commitCount = _commitCount > 0 ? _commitCount - 1 : 0;
    _cumProb = info.cumProb;

    _repertoire.navigateToLineMove(info.decisionPath);
    _decisionFen = info.decisionFen;
    _decisionPath = info.decisionPath;
    final (committed, suffix) = _splitByCoverage(info.decisionPath);
    _lastCommittedPath = committed;
    _uncommittedSuffix = suffix;
    _scratchTree = null;
    _scratchPath = TreePath.empty;
    _candidates = [];
    _candidatesLoading = true;
    _setPhase(BuildByPlayingPhase.awaitingUserMove);
    unawaited(_loadCandidates());
    return true;
  }

  /// Recover from [BuildByPlayingPhase.paused]: return to the decision point
  /// (external navigation) or retry the opponent fetch (explorer failure).
  Future<void> resume() async {
    if (_phase != BuildByPlayingPhase.paused) return;
    _pauseMessage = null;
    if (_pausedFromDecision) {
      _pausedFromDecision = false;
      _repertoire.navigateToLineMove(_decisionPath!);
      _setPhase(_scratchTree != null
          ? BuildByPlayingPhase.exploring
          : BuildByPlayingPhase.awaitingUserMove);
      if (_candidates.isEmpty && !_candidatesLoading) {
        _candidatesLoading = true;
        unawaited(_loadCandidates());
      }
    } else {
      _setPhase(BuildByPlayingPhase.advancing);
      await _advance();
    }
  }

  // ── Guards & helpers ───────────────────────────────────────────────

  /// External navigation guard: while parked at a decision point, anything
  /// else moving the repertoire cursor (line click, trap tour…) pauses the
  /// session instead of silently desyncing it.
  void _onRepertoireChanged() {
    if (_phase != BuildByPlayingPhase.awaitingUserMove &&
        _phase != BuildByPlayingPhase.exploring) {
      return;
    }
    if (_decisionFen != null && _repertoire.fen != _decisionFen) {
      _pause('Board moved away from the decision point — resume to return',
          fromDecision: true);
    }
  }

  void _pause(String message, {bool fromDecision = false}) {
    _pauseMessage = message;
    _pausedFromDecision = fromDecision;
    _setPhase(BuildByPlayingPhase.paused);
  }

  void _setPhase(BuildByPlayingPhase phase) {
    _phase = phase;
    notifyListeners();
  }

  Future<void> _loadCandidates() async {
    final epoch = _epoch;
    final fen = _decisionFen;
    final path = _decisionPath;
    final service = _candidateService;
    if (fen == null || path == null || service == null) return;

    List<CandidateMove> result = [];
    try {
      result = await service.getCandidates(
        fen: fen,
        isOurTurn: true,
        playAsWhite: _repertoire.isRepertoireWhite,
        pathFromRoot: path,
      );
    } catch (e) {
      debugPrint('[BuildByPlaying] Candidate load failed: $e');
    }
    if (epoch != _epoch || fen != _decisionFen) return;
    _candidates = result;
    _candidatesLoading = false;
    notifyListeners();
  }

  /// The repertoire's stored answer for the current position, or null when
  /// this is an uncovered decision point. Prefers the exact-path answer;
  /// falls back to any answer at the same position (transposition), guarded
  /// by SAN legality.
  String? _coveredAnswer(String fen, Position pos) {
    final tree = _repertoire.openingTree;
    if (tree == null) return null;

    OpeningTreeNode? node = tree.root;
    for (final san in _repertoire.currentMoveSequence) {
      node = node!.children[san];
      if (node == null) break;
    }
    if (node != null && node.children.isNotEmpty) {
      final san = _mostPlayedChildSan(node);
      if (san != null && pos.parseSan(san) != null) return san;
    }

    final transposed = tree.fenToNodes[normalizeFen(fen)];
    if (transposed != null) {
      for (final n in transposed) {
        for (final san in n.children.keys) {
          if (pos.parseSan(san) != null) return san;
        }
      }
    }
    return null;
  }

  String? _mostPlayedChildSan(OpeningTreeNode node) {
    String? best;
    var bestGames = -1;
    for (final entry in node.children.entries) {
      if (entry.value.gamesPlayed > bestGames) {
        bestGames = entry.value.gamesPlayed;
        best = entry.key;
      }
    }
    return best;
  }

  /// Split [fullPath] into (prefix already in the repertoire file, remainder)
  /// by walking the opening tree move-by-move. Matches the writer's
  /// exact-mainline chaining semantics.
  (List<String>, List<String>) _splitByCoverage(List<String> fullPath) {
    final tree = _repertoire.openingTree;
    final committed = <String>[];
    var i = 0;
    if (tree != null) {
      OpeningTreeNode? node = tree.root;
      for (; i < fullPath.length; i++) {
        node = node!.children[fullPath[i]];
        if (node == null) break;
        committed.add(fullPath[i]);
      }
    }
    return (committed, fullPath.sublist(i));
  }

  String _fenForSans(List<String> sans) {
    var pos = _positionFromFen(_repertoire.tree.startingFen) ?? Chess.initial;
    for (final san in sans) {
      final move = pos.parseSan(san);
      if (move == null) break;
      pos = pos.play(move);
    }
    return pos.fen;
  }

  Position? _positionFromFen(String fen) {
    try {
      return Chess.fromSetup(Setup.parseFen(fen));
    } catch (_) {
      return null;
    }
  }

  static bool _startsWith(List<String> list, List<String> prefix) {
    if (list.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (list[i] != prefix[i]) return false;
    }
    return true;
  }

  /// Select the opponent replies to cover at a position, mirroring the
  /// generation engine's knob semantics: most popular first, take while the
  /// covered mass is below [oppMassTarget] and the count below
  /// [oppMaxChildren]; replies played at least [coverMinProb] of the time are
  /// always included, bypassing both caps.
  @visibleForTesting
  static List<ExplorerMove> selectOpponentReplies(
    List<ExplorerMove> moves, {
    required double coverMinProb,
    required double oppMassTarget,
    required int oppMaxChildren,
  }) {
    final sorted = List<ExplorerMove>.from(moves)
      ..sort((a, b) => b.playFraction.compareTo(a.playFraction));
    final selected = <ExplorerMove>[];
    var mass = 0.0;
    for (final m in sorted) {
      if (m.san.isEmpty || m.total <= 0) continue;
      final forced = m.playFraction >= coverMinProb;
      final underCaps =
          selected.length < oppMaxChildren && mass < oppMassTarget;
      // Sorted descending: once a reply is neither forced nor under the
      // caps, no later reply can qualify either.
      if (!forced && !underCaps) break;
      selected.add(m);
      mass += m.playFraction;
    }
    return selected;
  }
}

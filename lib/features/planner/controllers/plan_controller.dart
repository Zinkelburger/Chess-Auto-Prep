/// The planning walk: from a start position, descend the opening tree, ask
/// the user at *their own* forks, split at the opponent's tabiyas, and cut a
/// chapter wherever the walk stops.
///
/// Rules, in one place so they can be read together:
///
/// - **Our move.** If the book forks here ([tabiyaThreshold]) we ask, unless
///   the user's chapters already play exactly one move here — then that move
///   is taken silently ("your Advance chapter plays …c5"). Their own games
///   pre-tick but never decide. Every chosen move continues the walk on its
///   own path. "Skip — let the engine choose" and "Stop here" both cut a
///   chapter at this position.
/// - **Their move.** Not a fork (score below threshold): cut a chapter here;
///   the engine covers replies. A fork: every reply at or above
///   [chapterShare] continues on its own path (the user can untick/tick),
///   and if the replies left over still carry [minShare] of games or more,
///   one "sidelines" chapter is cut here that excludes the split-off replies,
///   so nothing above the coverage floor is silently dropped and no two
///   chapters build the same lines.
/// - **Depth.** Past [maxPly] or out of book the walk always cuts.
///
/// **Walking your own games** ([PlanBasis.ownGames]) keeps every rule above
/// but swaps the book for the user's games as the thing being walked: a
/// position is a question when they reached it in at least [ownFloor] games
/// (their move: which of the moves they played stays; the opponent's move:
/// which of the replies they met get set up), and the walk stops — asking
/// first — where their games thin out. Book and Maia still fill the columns,
/// so a move they never tried can still be added at any question. This is
/// "turn my games into a repertoire", one decision at a time.
///
/// Every decision is a snapshot on a stack, so "back" is exact. Chapters and
/// build points live in a [PlanChapterLedger]; what a question shows comes
/// from a [PlanCandidateAssembler].
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../../utils/fen_utils.dart';
import '../../../utils/movetext_builder.dart';
import '../../../utils/safe_change_notifier.dart';
import '../models/plan_models.dart';
import '../models/plan_starting_line.dart';
import '../services/plan_data_source.dart';
import '../services/plan_knowledge.dart';
import '../services/san_paths.dart';
import 'plan_candidate_assembler.dart';
import 'plan_chapter_ledger.dart';

enum PlanPhase { start, walking, review }

/// Everything an answer can change, taken *before* the answer so that
/// "back" restores the exact card the user was looking at — its kind too,
/// not just its position — and forgets what the undone branch learned.
class _Snapshot {
  final List<List<String>> frontier;
  final PlanChapterLedgerState ledger;
  final PlanStep? step;
  final Map<String, List<String>> seenFen;
  final Map<String, List<String>> ourAnswerByFen;
  final List<List<String>> manualRoots;
  final int decisionCount;
  const _Snapshot({
    required this.frontier,
    required this.ledger,
    required this.step,
    required this.seenFen,
    required this.ourAnswerByFen,
    required this.manualRoots,
    required this.decisionCount,
  });
}

class PlanController extends ChangeNotifier with SafeChangeNotifier {
  PlanController({
    required this.source,
    required this.isWhite,
    this.knowledge = PlanKnowledge.empty,
    this.basis = PlanBasis.book,
    this.elo = 1800,
    this.minShare = 0.05,
    this.chapterShare = 0.03,
    this.chapterMass = 0.10,
    this.tabiyaThreshold = 12,
    this.maxPly = 40,
  }) : _ledger = PlanChapterLedger(
         nameFor: source.nameFor,
         chapterMass: chapterMass,
       );

  final PlanDataSource source;
  final bool isWhite;
  PlanKnowledge knowledge;
  PlanBasis basis;
  int elo;

  /// Coverage floor: opponent replies below this share are the engine's
  /// business, not the plan's.
  double minShare;

  /// A reply at or above this share at a tabiya is set up as its own line.
  final double chapterShare;

  /// A branch becomes its own *chapter* only when it carries at least this
  /// much of the games from the walk's root AND leads into a differently
  /// named opening family — the London gets a chapter, 7.Bxf6 does not.
  final double chapterMass;

  /// Below this ECO tabiya score a position is not a fork.
  final int tabiyaThreshold;
  final int maxPly;

  /// Walking own games: a question needs at least this many games at a
  /// position, however few there are at the root.
  static const int minOwnGames = 3;

  /// How many rows get database / engine evaluations per question.
  int dbFillLimit = 10;
  int engineFillLimit = 8;

  final PlanChapterLedger _ledger;

  PlanPhase _phase = PlanPhase.start;
  PlanPhase get phase => _phase;

  /// Paths still to be walked, in order.
  final List<List<String>> _frontier = [];

  /// Probability of reaching each path from the walk's root: 1.0 at the root,
  /// multiplied by the opponent's share at every reply we descend into (our
  /// own moves cost nothing — we choose them). Keyed by [sanPathKey].
  final Map<String, double> _reach = {};
  final List<_Snapshot> _history = [];

  PlanStep? _step;
  PlanStep? get step => _step;

  /// Positions still to be walked, for the "N open" counter.
  int get openBranches => _frontier.length + (_step == null ? 0 : 1);
  int get answered => _history.length;

  /// Chapters that have something to build. Chapters are opened eagerly as
  /// the walk crosses into a new opening family, but one that never received
  /// a build point (the family changed again before any line ended there) is
  /// bookkeeping, not a chapter — it is never shown and never created.
  List<PlanChapter> get chapters => _ledger.chapters;
  bool get canGoBack => _history.isNotEmpty;

  /// Log of what was decided, in order, for the "Plan so far" tree.
  final List<String> decisions = [];

  /// Positions this walk has already handled (normalized FEN → the path it
  /// was reached by first). A second move order into the same position is a
  /// transposition: our answer is reused, and a leaf is not cut twice.
  final Map<String, List<String>> _seenFen = {};

  /// Our answers by position, so a fork reached by another move order is
  /// answered the same way without asking.
  final Map<String, List<String>> _ourAnswerByFen = {};

  /// Line roots the user asked to keep setting up past the book's end. Every
  /// position on or below such a root is asked as an ordinary question, with
  /// no more leaf confirmations, until the user presses Stop there.
  final List<List<String>> _manualRoots = [];

  /// Walking own games: the question floor per starting line, keyed by
  /// [sanPathKey] of the root — [chapterShare] of the games there, never
  /// fewer than [minOwnGames].
  final Map<String, int> _ownFloors = {};

  /// Candidates whose on-demand engine run is in flight (SAN), for spinners.
  final Set<String> evaluating = {};

  /// Bumped by anything that invalidates in-flight work (start, reset, back,
  /// finish); awaited work compares its own epoch before touching state.
  int _epoch = 0;

  bool _patchNotifyScheduled = false;

  /// Walking own games: a position is a question when at least this many of
  /// the user's games reached it. Resolved at [start] from the games at the
  /// root — see [_ownFloors].
  int get ownFloor => _ownFloorFor(_step?.moves ?? const []);

  int _ownFloorFor(List<String> path) {
    for (var n = path.length; n >= 0; n--) {
      final found = _ownFloors[sanPathKey(path.take(n).toList())];
      if (found != null) return found;
    }
    return minOwnGames;
  }

  bool get _walksOwnGames => basis == PlanBasis.ownGames;

  PlanCandidateAssembler get _assembler => PlanCandidateAssembler(
    knowledge: knowledge,
    walksOwnGames: _walksOwnGames,
    chapterShare: chapterShare,
  );

  double reachOf(List<String> path) => _reach[sanPathKey(path)] ?? 1.0;
  void _setReach(List<String> path, double p) => _reach[sanPathKey(path)] = p;

  /// Whether [path] is inside a line the user is setting up by hand.
  bool isManual(List<String> path) =>
      _manualRoots.any((root) => sanPathStartsWith(path, root));

  // ── Lifecycle ──────────────────────────────────────────────────────────

  Future<void> start(List<String> rootMoves) =>
      startMany([PlanStartingLine(moves: rootMoves)]);

  /// Walk every supplied system, or send the exact roots straight to review.
  Future<void> startMany(
    List<PlanStartingLine> roots, {
    bool askQuestions = true,
  }) async {
    PlanStartingLine.validate(roots);
    final epoch = ++_epoch;
    _manualRoots.clear();
    _seenFen.clear();
    _ourAnswerByFen.clear();
    _frontier
      ..clear()
      ..addAll(roots.map((r) => List.of(r.moves)));
    _reach.clear();
    _ownFloors.clear();
    _ledger.clear();
    _history.clear();
    decisions.clear();
    _step = null;
    _phase = PlanPhase.walking;
    for (final root in roots) {
      _setReach(root.moves, 1.0);
      if (_walksOwnGames) {
        // Validated above: every root is playable.
        final rootGames = knowledge.ownGamesAt(fenAfterSanPath(root.moves)!);
        _ownFloors[sanPathKey(root.moves)] = math.max(
          minOwnGames,
          (rootGames * chapterShare).round(),
        );
      }
      final chapter = await _ledger.chapterFor(root.moves);
      if (epoch != _epoch) return;
      if (root.name.isNotEmpty) chapter.name = root.name;
    }
    if (!askQuestions) {
      await finish();
      return;
    }
    notifyListeners();
    await _advance();
  }

  void reset() {
    _epoch++;
    _frontier.clear();
    _ledger.clear();
    _history.clear();
    decisions.clear();
    _step = null;
    _phase = PlanPhase.start;
    notifyListeners();
  }

  /// Everything decided so far, as a plan (also valid mid-walk: open
  /// branches become chapters at their current positions).
  Future<RepertoirePlan> finish() async {
    _epoch++;
    final pending = [if (_step != null) _step!.moves, ..._frontier];
    for (final path in pending) {
      await _ledger.cut(path, reason: 'left to the engine from here');
    }
    _frontier.clear();
    _step = null;
    _phase = PlanPhase.review;
    final chapters = _ledger.finish();
    notifyListeners();
    return RepertoirePlan(
      isWhite: isWhite,
      elo: elo,
      minShare: minShare,
      chapters: chapters,
    );
  }

  // ── Answers ────────────────────────────────────────────────────────────

  /// Our-move fork: continue with each chosen move.
  Future<void> choose(Iterable<String> sans) async {
    final step = _step;
    if (step == null || step.kind != PlanStepKind.ourMove) return;
    final picks = sans.toList();
    if (picks.isEmpty) return;
    _pushHistory();
    _ourAnswerByFen[normalizeFen(step.fen)] = picks;
    // Two of our own systems (…e6 and …c6) are two chapters; a choice
    // that stays in the same family stays in the chapter.
    await _continueWithOurMoves(step.moves, picks);
    decisions.add('${_ref(step.moves.length)}: you play ${picks.join(' / ')}');
    _step = null;
    await _advance();
  }

  /// Their-move step: the ticked replies are set up, and only they. A
  /// repertoire is what you chose; nothing is added for what you did not.
  Future<void> acceptCoverage(Iterable<String> split) async {
    final step = _step;
    if (step == null || step.kind != PlanStepKind.theirMove) return;
    _pushHistory();
    final splitSans = split.toList();
    final shareOf = {
      for (final c in step.candidates) c.san: _reachShare(c) ?? 0.0,
    };
    for (final san in splitSans.reversed) {
      final child = [...step.moves, san];
      _setReach(child, reachOf(step.moves) * (shareOf[san] ?? 0.0));
      await _assignChapter(child, parent: step.moves, ourChoice: false);
      _frontier.insert(0, child);
    }
    if (splitSans.isEmpty) {
      // Nothing ticked: this line ends here and the engine takes it.
      await _ledger.cut(step.moves, reason: 'generate from here');
    }
    decisions.add(
      '${_ref(step.moves.length)}: set up ${splitSans.isEmpty ? 'nothing more — generate from here' : splitSans.join(', ')}',
    );
    _step = null;
    await _advance();
  }

  /// Cut a chapter at the current position and move on.
  Future<void> stopHere() async {
    final step = _step;
    if (step == null) return;
    _pushHistory();
    // Stopping ends the manual stretch for this line only.
    _manualRoots.removeWhere((root) => sanPathStartsWith(step.moves, root));
    await _ledger.cut(step.moves, reason: 'you stopped here');
    decisions.add('${_ref(step.moves.length)}: generate from here');
    _step = null;
    await _advance();
  }

  /// Our-move fork left to the engine — same as stopping here.
  Future<void> skipToEngine() => stopHere();

  /// Transposition accepted: the earlier line covers this; nothing to cut.
  Future<void> skipTransposition() async {
    final step = _step;
    if (step == null || step.kind != PlanStepKind.transposition) return;
    _pushHistory();
    decisions.add(
      '${_ref(step.moves.length)}: transposes to '
      '${_label(step.transposesTo ?? const [])} — covered there',
    );
    _step = null;
    await _advance();
  }

  /// Transposition refused: treat this move order as its own line.
  Future<void> setUpSeparately() async {
    final step = _step;
    if (step == null || step.kind != PlanStepKind.transposition) return;
    _pushHistory();
    _seenFen[normalizeFen(step.fen)] = List.of(step.moves);
    _manualRoots.add(List.of(step.moves));
    _step = null;
    await _openStep(step.moves);
  }

  /// Leaf confirmed: cut the chapter here and move on.
  Future<void> confirmLeaf() async {
    final step = _step;
    if (step == null || step.kind != PlanStepKind.confirmLeaf) return;
    _pushHistory();
    await _ledger.cut(step.moves, reason: 'you chose to generate from here');
    decisions.add('${_ref(step.moves.length)}: generate from here');
    _step = null;
    await _advance();
  }

  /// Leaf refused: keep setting up from this position — ask here as a normal
  /// question even though the book is thin.
  Future<void> continueSetup() async {
    final step = _step;
    if (step == null || step.kind != PlanStepKind.confirmLeaf) return;
    _pushHistory();
    _manualRoots.add(List.of(step.moves));
    _step = null;
    await _openStep(step.moves);
  }

  Future<void> back() async {
    if (_history.isEmpty) return;
    _epoch++;
    final snap = _history.removeLast();
    _frontier
      ..clear()
      ..addAll(snap.frontier.map(List<String>.of));
    _ledger.restore(snap.ledger);
    _seenFen
      ..clear()
      ..addAll(snap.seenFen);
    _ourAnswerByFen
      ..clear()
      ..addAll(snap.ourAnswerByFen);
    _manualRoots
      ..clear()
      ..addAll(snap.manualRoots.map(List<String>.of));
    // Silent decisions (a chapter's move, a reused answer) are logged without
    // a snapshot of their own, so truncate to the length at answer time
    // rather than popping one entry.
    if (decisions.length > snap.decisionCount) {
      decisions.removeRange(snap.decisionCount, decisions.length);
    }
    _step = null;
    _phase = PlanPhase.walking;
    final step = snap.step;
    if (step == null) {
      await _advance();
      return;
    }
    switch (step.kind) {
      case PlanStepKind.confirmLeaf:
        await _openLeafConfirm(step.moves, step.fen);
      case PlanStepKind.transposition:
        await _openTransposition(
          step.moves,
          step.fen,
          step.transposesTo ?? const [],
        );
      case PlanStepKind.ourMove:
      case PlanStepKind.theirMove:
        await _openStep(step.moves);
    }
  }

  // ── Candidates of the open question ────────────────────────────────────

  /// Run the engine for one candidate that has no evaluation yet.
  Future<void> evaluateCandidate(String san) async {
    final step = _step;
    if (step == null || step.loading || evaluating.contains(san)) return;
    if (!step.candidates.any((c) => c.san == san)) return;
    final after = fenAfterSanPath([...step.moves, san]);
    if (after == null) return;
    evaluating.add(san);
    notifyListeners();
    final result = await source.engineEval(after);
    evaluating.remove(san);
    if (!_isStepAt(step.moves)) {
      notifyListeners();
      return;
    }
    if (result != null) {
      _replaceCandidate(
        san,
        (c) => c.copyWith(
          evalCp: result.cp,
          evalDepth: result.depth,
          evalSource: 'Stockfish',
        ),
      );
    }
    notifyListeners();
  }

  /// A move the user played on the board at the current question: make it a
  /// candidate (it may be one Maia never listed) and select nothing else —
  /// the caller decides selection.
  void addCandidate(String san) {
    final step = _step;
    if (step == null || step.loading) return;
    if (step.candidates.any((c) => c.san == san)) return;
    _step = step.copyWith(
      candidates: [
        ...step.candidates,
        PlanCandidate(san: san),
      ],
    );
    notifyListeners();
  }

  // ── The walk ───────────────────────────────────────────────────────────

  void _pushHistory() {
    _history.add(
      _Snapshot(
        frontier: _frontier.map(List<String>.of).toList(),
        ledger: _ledger.snapshot(),
        step: _step,
        seenFen: Map.of(_seenFen),
        ourAnswerByFen: Map.of(_ourAnswerByFen),
        manualRoots: _manualRoots.map(List<String>.of).toList(),
        decisionCount: decisions.length,
      ),
    );
  }

  Future<void> _advance() async {
    final epoch = _epoch;
    while (_frontier.isNotEmpty) {
      final path = _frontier.removeAt(0);
      final decided = await _decideWithoutAsking(path);
      if (epoch != _epoch) return;
      // A leaf confirmation is a step too: stop the loop and wait.
      if (_step != null) return;
      if (decided) continue;
      await _openStep(path);
      return;
    }
    if (epoch != _epoch) return;
    // Nothing left to ask.
    _phase = PlanPhase.review;
    _ledger.finish();
    notifyListeners();
  }

  /// Handles [path] if no question is needed. Returns true when it did.
  Future<bool> _decideWithoutAsking(List<String> path) async {
    final fen = fenAfterSanPath(path);
    if (fen == null) {
      await _ledger.cut(path, reason: 'unplayable path');
      return true;
    }
    if (path.length >= maxPly) {
      await _ledger.cut(path, reason: 'deep enough — engine from here');
      return true;
    }
    final key = normalizeFen(fen);
    final ourMove = _isOurMove(fen);

    // Transposition: this position was already set up via another move
    // order. Reuse rather than ask twice.
    final earlier = _seenFen[key];
    if (earlier != null && sanPathKey(earlier) != sanPathKey(path)) {
      final answer = ourMove ? _ourAnswerByFen[key] : null;
      if (answer != null) {
        await _continueWithOurMoves(path, answer);
        decisions.add(
          '${_ref(path.length)}: same position as ${_label(earlier)} — '
          '${answer.join(' / ')} again',
        );
        return true;
      }
      // A position already covered by a chapter (or an opponent node already
      // split): show it and let the user skip or set it up separately.
      await _openTransposition(path, fen, earlier);
      return true;
    }
    _seenFen.putIfAbsent(key, () => List.of(path));

    if (_walksOwnGames) {
      // Own games: a question wherever enough of them reached this position;
      // where they thin out the walk stops — asking first, never silently.
      if (knowledge.ownGamesAt(fen) < _ownFloorFor(path) && !isManual(path)) {
        await _openLeafConfirm(path, fen);
        return true;
      }
    } else {
      final score = await source.tabiyaScore(path);
      if (score < tabiyaThreshold && !isManual(path)) {
        // The book does not fork here. For the opponent's move that is not
        // the last word: two replies can both be common and lead to
        // different systems (7.Bxf6 vs 7.Bh4 in the QGD — a capture and a
        // retreat, two structures) while the book lists lines under only one
        // of them. Ask Maia, and treat that as a fork too.
        if (!ourMove && await _isStructuralFork(fen, path)) return false;
        // Otherwise the walk *would* stop here — but never silently: show
        // the position and let the user confirm, or keep setting up.
        await _openLeafConfirm(path, fen);
        return true;
      }
    }

    if (ourMove) {
      final known = knowledge.chapterMovesAt(fen);
      if (known.length == 1) {
        await _continueWithOurMoves(path, [known.first]);
        decisions.add(
          '${_ref(path.length)}: ${known.first} (already in your chapters)',
        );
        return true;
      }
    }
    return false;
  }

  /// Whether the opponent's common replies here diverge structurally: at
  /// least two at or above [chapterShare] that reach different ECO codes, or
  /// where one captures and another does not.
  Future<bool> _isStructuralFork(String fen, List<String> path) async {
    if (path.length + 2 >= maxPly) return false;
    final candidates = await source.candidates(
      fen: fen,
      moves: path,
      ourMove: false,
      elo: elo,
    );
    final big = [
      for (final c in candidates)
        if ((c.share ?? 0) >= chapterShare) c,
    ];
    if (big.length < 2) return false;
    final codes = {
      for (final c in big)
        if (c.eco != null) c.eco,
    };
    if (codes.length >= 2) return true;
    final captures = big.where((c) => c.san.contains('x')).length;
    return captures > 0 && captures < big.length;
  }

  /// Our moves [sans] from [path] each continue the walk on their own path,
  /// in order, at the front of the frontier.
  Future<void> _continueWithOurMoves(
    List<String> path,
    List<String> sans,
  ) async {
    for (final san in sans.reversed) {
      final child = [...path, san];
      _setReach(child, reachOf(path));
      await _assignChapter(child, parent: path, ourChoice: true);
      _frontier.insert(0, child);
    }
  }

  Future<void> _assignChapter(
    List<String> child, {
    required List<String> parent,
    required bool ourChoice,
  }) => _ledger.assign(
    child,
    parent: parent,
    ourChoice: ourChoice,
    reach: reachOf(child),
  );

  Future<void> _openTransposition(
    List<String> path,
    String fen,
    List<String> earlier,
  ) async {
    final name = await source.nameFor(path);
    _step = PlanStep(
      moves: path,
      kind: PlanStepKind.transposition,
      fen: fen,
      candidates: const [],
      loading: false,
      positionName: name,
      preselected: const {},
      reachProb: reachOf(path),
      transposesTo: earlier,
      ownGames: knowledge.ownGamesAt(fen),
    );
    notifyListeners();
  }

  Future<void> _openLeafConfirm(List<String> path, String fen) async {
    final name = await source.nameFor(path);
    _step = PlanStep(
      moves: path,
      kind: PlanStepKind.confirmLeaf,
      fen: fen,
      candidates: const [],
      loading: false,
      positionName: name,
      preselected: const {},
      reachProb: reachOf(path),
      ownGames: knowledge.ownGamesAt(fen),
    );
    notifyListeners();
  }

  Future<void> _openStep(List<String> path) async {
    final epoch = _epoch;
    // Every path reaching here was played through by [_decideWithoutAsking].
    final fen = fenAfterSanPath(path)!;
    final ourMove = _isOurMove(fen);
    final name = await source.nameFor(path);
    _step = PlanStep(
      moves: path,
      kind: ourMove ? PlanStepKind.ourMove : PlanStepKind.theirMove,
      fen: fen,
      candidates: const [],
      loading: true,
      positionName: name,
      preselected: const {},
      reachProb: reachOf(path),
      ownGames: knowledge.ownGamesAt(fen),
    );
    notifyListeners();

    final sourced = await source.candidates(
      fen: fen,
      moves: path,
      ourMove: ourMove,
      elo: elo,
    );
    if (epoch != _epoch || !_isStepAt(path)) return;

    final assembled = _assembler.assemble(
      sourced,
      fen: fen,
      ourMove: ourMove,
      ownFloor: _ownFloorFor(path),
    );
    _step = _step!.copyWith(
      candidates: assembled.candidates,
      loading: false,
      preselected: assembled.preselected,
    );
    notifyListeners();
    // The question is on screen; now the slow parts land row by row: the
    // database first (all at once), then Stockfish for whatever it missed.
    unawaited(_fillEvals(path, epoch));
  }

  Future<void> _fillEvals(List<String> path, int epoch) async {
    final step = _step;
    if (step == null || !listEquals(step.moves, path)) return;
    final targets = step.candidates.take(dbFillLimit).toList();
    await Future.wait([
      for (final c in targets) _fillDbEval(path, c.san, epoch),
    ]);
    if (epoch != _epoch || isDisposed) return;
    final missing = _candidatesAt(path)
        .where((c) => c.evalCp == null)
        .take(engineFillLimit)
        .map((c) => c.san)
        .toList();
    for (final san in missing) {
      if (epoch != _epoch || isDisposed || !_isStepAt(path)) return;
      await evaluateCandidate(san);
    }
  }

  Future<void> _fillDbEval(List<String> path, String san, int epoch) async {
    final after = fenAfterSanPath([...path, san]);
    if (after == null) return;
    final hit = await source.dbEval(after);
    if (hit == null || epoch != _epoch || isDisposed) return;
    if (!_isStepAt(path)) return;
    _replaceCandidate(
      san,
      (c) => c.copyWith(
        evalCp: hit.cp,
        evalDepth: hit.depth,
        evalSource: hit.source,
      ),
    );
    _notifyCoalesced();
  }

  /// Replace one candidate of the current step.
  void _replaceCandidate(
    String san,
    PlanCandidate Function(PlanCandidate) update,
  ) {
    final current = _step;
    if (current == null) return;
    _step = current.copyWith(
      candidates: [
        for (final c in current.candidates) c.san == san ? update(c) : c,
      ],
    );
  }

  /// Patches that land in the same event-loop turn — the database answers
  /// for a whole question arrive together — coalesce into one notification;
  /// a patch that arrives on its own still shows up on its own.
  void _notifyCoalesced() {
    if (_patchNotifyScheduled) return;
    _patchNotifyScheduled = true;
    scheduleMicrotask(() {
      _patchNotifyScheduled = false;
      if (!isDisposed) notifyListeners();
    });
  }

  /// The share an opponent reply multiplies the reach by: their share of
  /// the user's own games when walking those, Maia's otherwise.
  double? _reachShare(PlanCandidate c) =>
      _walksOwnGames ? (c.ownShare ?? c.share) : c.share;

  // ── Helpers ────────────────────────────────────────────────────────────

  /// Whether the open question is still the one at [path].
  bool _isStepAt(List<String> path) {
    final step = _step;
    return step != null && listEquals(step.moves, path);
  }

  List<PlanCandidate> _candidatesAt(List<String> path) =>
      _isStepAt(path) ? _step!.candidates : const [];

  bool _isOurMove(String fen) => isWhiteToMove(fen) == isWhite;

  static String _label(List<String> moves) =>
      buildNumberedMovetext(moves, compact: true);

  static String _ref(int ply) => 'move ${ply ~/ 2 + 1}';
}

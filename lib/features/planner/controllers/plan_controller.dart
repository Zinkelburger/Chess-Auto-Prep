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
/// Every decision is a snapshot on a stack, so "back" is exact.
library;

import 'dart:async';

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

import '../../../utils/chess_utils.dart';
import '../../../utils/fen_utils.dart';
import '../../../services/generation/course/opening_namer.dart'
    show formatMoveReference;
import '../models/plan_models.dart';
import '../services/plan_data_source.dart';
import '../services/plan_knowledge.dart';

enum PlanPhase { start, walking, review }

class _Snapshot {
  final List<List<String>> frontier;
  final List<PlanChapter> chapters;
  final Map<String, int> chapterOf;
  final List<String>? currentPath;
  const _Snapshot(
    this.frontier,
    this.chapters,
    this.chapterOf,
    this.currentPath,
  );
}

class PlanController extends ChangeNotifier {
  PlanController({
    required this.source,
    required this.isWhite,
    this.knowledge = PlanKnowledge.empty,
    this.elo = 1800,
    this.minShare = 0.05,
    this.chapterShare = 0.03,
    this.chapterMass = 0.10,
    this.tabiyaThreshold = 12,
    this.maxPly = 40,
  });

  final PlanDataSource source;
  final bool isWhite;
  PlanKnowledge knowledge;
  int elo;

  /// Coverage floor: opponent replies below this share are the engine's
  /// business, not the plan's.
  double minShare;

  /// A reply at or above this share at a tabiya is set up as its own line.
  double chapterShare;

  /// A branch becomes its own *chapter* only when it carries at least this
  /// much of the games from the walk's root AND leads into a differently
  /// named opening family — the London gets a chapter, 7.Bxf6 does not.
  double chapterMass;

  /// Below this ECO tabiya score a position is not a fork.
  int tabiyaThreshold;
  int maxPly;

  PlanPhase _phase = PlanPhase.start;
  PlanPhase get phase => _phase;

  final List<List<String>> _frontier = [];
  final List<PlanChapter> _chapters = [];

  /// Which chapter each walked path belongs to (index into [_chapters]),
  /// keyed by the joined path.
  final Map<String, int> _chapterOf = {};

  /// Probability of reaching each path from the walk's root: 1.0 at the root,
  /// multiplied by the opponent's share at every reply we descend into (our
  /// own moves cost nothing — we choose them). Keyed by the joined path.
  final Map<String, double> _reach = {};
  double reachOf(List<String> path) => _reach[path.join(' ')] ?? 1.0;
  void _setReach(List<String> path, double p) => _reach[path.join(' ')] = p;
  final List<_Snapshot> _history = [];

  PlanStep? _step;
  PlanStep? get step => _step;

  /// Positions still to be walked, for the "N open" counter.
  int get openBranches => _frontier.length + (_step == null ? 0 : 1);
  int get answered => _history.length;
  List<PlanChapter> get chapters => List.unmodifiable(_chapters);
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

  int _epoch = 0;

  // ── Lifecycle ──────────────────────────────────────────────────────────

  Future<void> start(List<String> rootMoves) async {
    _epoch++;
    _manualRoots.clear();
    _seenFen.clear();
    _ourAnswerByFen.clear();
    _chapterOf.clear();
    _frontier
      ..clear()
      ..add(List.of(rootMoves));
    _reach
      ..clear()
      ..[rootMoves.join(' ')] = 1.0;
    _chapters.clear();
    _history.clear();
    decisions.clear();
    _step = null;
    _phase = PlanPhase.walking;
    // The root is the first chapter; everything belongs to it until the
    // mass splits into another named system.
    await _chapterFor(rootMoves);
    notifyListeners();
    await _advance();
  }

  void reset() {
    _epoch++;
    _frontier.clear();
    _chapters.clear();
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
      await _cutChapter(path, reason: 'left to the engine from here');
    }
    _frontier.clear();
    _step = null;
    _phase = PlanPhase.review;
    _disambiguateNames();
    notifyListeners();
    return RepertoirePlan(
      isWhite: isWhite,
      elo: elo,
      minShare: minShare,
      chapters: List.of(_chapters),
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
    for (final san in picks.reversed) {
      final child = [...step.moves, san];
      _setReach(child, reachOf(step.moves));
      // Two of our own systems (…e6 and …c6) are two chapters; a choice
      // that stays in the same family stays in the chapter.
      await _assignChapter(child, parent: step.moves, ourChoice: true);
      _frontier.insert(0, child);
    }
    decisions.add('${_ref(step.moves.length)}: you play ${picks.join(' / ')}');
    _step = null;
    await _advance();
  }

  /// Their-move tabiya: [split] get their own chapters; the rest stay with a
  /// sidelines chapter here (if they carry enough games).
  /// [coverRest] — whether everything the opponent plays here *besides* the
  /// ticked replies should also be built (as one line rooted here that
  /// excludes them). Off by default: a repertoire is what was ticked.
  Future<void> acceptCoverage(
    Iterable<String> split, {
    bool coverRest = false,
  }) async {
    final step = _step;
    if (step == null || step.kind != PlanStepKind.theirMove) return;
    _pushHistory();
    final splitSans = split.toList();
    final shareOf = {for (final c in step.candidates) c.san: c.share ?? 0.0};
    for (final san in splitSans.reversed) {
      final child = [...step.moves, san];
      _setReach(child, reachOf(step.moves) * (shareOf[san] ?? 0.0));
      await _assignChapter(child, parent: step.moves, ourChoice: false);
      _frontier.insert(0, child);
    }
    final rest = step.candidates.where((c) => !splitSans.contains(c.san));
    final restMass = rest.fold<double>(0, (s, c) => s + (c.share ?? 0));
    var restCovered = false;
    if (splitSans.isEmpty) {
      await _cutChapter(step.moves, reason: 'all replies covered here');
      restCovered = true;
    } else if (coverRest && restMass >= minShare) {
      await _cutChapter(
        step.moves,
        excludeReplies: splitSans,
        reason: 'everything else played here',
      );
      restCovered = true;
    }
    decisions.add(
      '${_ref(step.moves.length)}: set up ${splitSans.join(', ')}'
      '${restCovered && splitSans.isNotEmpty ? ' + everything else' : ''}'
      '${!coverRest && splitSans.isNotEmpty ? ' only' : ''}',
    );
    _step = null;
    await _advance();
  }

  /// Share of games at the current their-move step not covered by [split].
  double restMassFor(Iterable<String> split) {
    final step = _step;
    if (step == null) return 0;
    final chosen = split.toSet();
    return step.candidates
        .where((c) => !chosen.contains(c.san))
        .fold<double>(0, (s, c) => s + (c.share ?? 0));
  }

  /// Cut a chapter at the current position and move on.
  Future<void> stopHere() async {
    final step = _step;
    if (step == null) return;
    _pushHistory();
    // Stopping ends the manual stretch for this line only.
    _manualRoots.removeWhere(
      (r) =>
          r.length <= step.moves.length &&
          List.generate(r.length, (i) => r[i] == step.moves[i]).every((b) => b),
    );
    await _cutChapter(step.moves, reason: 'you stopped here');
    decisions.add('${_ref(step.moves.length)}: generate from here');
    _step = null;
    await _advance();
  }

  /// Our-move fork left to the engine — same as stopping here.
  Future<void> skipToEngine() => stopHere();

  Future<void> back() async {
    if (_history.isEmpty) return;
    _epoch++;
    final snap = _history.removeLast();
    _frontier
      ..clear()
      ..addAll(snap.frontier.map(List<String>.of));
    _chapters
      ..clear()
      ..addAll([for (final c in snap.chapters) c.copy()]);
    _chapterOf
      ..clear()
      ..addAll(snap.chapterOf);
    if (decisions.isNotEmpty) decisions.removeLast();
    _step = null;
    _phase = PlanPhase.walking;
    if (snap.currentPath != null) {
      await _openStep(snap.currentPath!);
    } else {
      await _advance();
    }
  }

  // ── The walk ───────────────────────────────────────────────────────────

  void _pushHistory() {
    _history.add(
      _Snapshot(
        _frontier.map(List<String>.of).toList(),
        [for (final c in _chapters) c.copy()],
        Map.of(_chapterOf),
        _step?.moves,
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
    _disambiguateNames();
    notifyListeners();
  }

  /// Handles [path] if no question is needed. Returns true when it did.
  Future<bool> _decideWithoutAsking(List<String> path) async {
    final fen = _fenAfter(path);
    if (fen == null) {
      await _cutChapter(path, reason: 'unplayable path');
      return true;
    }
    if (path.length >= maxPly) {
      await _cutChapter(path, reason: 'deep enough — engine from here');
      return true;
    }
    final key = normalizeFen(fen);
    final ourMove = _isOurMove(fen);

    // Transposition: this position was already set up via another move
    // order. Reuse rather than ask twice.
    final earlier = _seenFen[key];
    if (earlier != null && earlier.join(' ') != path.join(' ')) {
      if (ourMove && _ourAnswerByFen[key] != null) {
        for (final san in _ourAnswerByFen[key]!.reversed) {
          final child = [...path, san];
          _setReach(child, reachOf(path));
          await _assignChapter(child, parent: path, ourChoice: true);
          _frontier.insert(0, child);
        }
        decisions.add(
          '${_ref(path.length)}: same position as ${_label(earlier)} — '
          '${_ourAnswerByFen[key]!.join(' / ')} again',
        );
        return true;
      }
      // A position already covered by a chapter (or an opponent node already
      // split): show it and let the user skip or set it up separately.
      await _openTransposition(path, fen, earlier);
      return true;
    }
    _seenFen.putIfAbsent(key, () => List.of(path));

    final score = await source.tabiyaScore(path);

    if (score < tabiyaThreshold && !isManual(path)) {
      // The book does not fork here. For the opponent's move that is not the
      // last word: two replies can both be common and lead to different
      // systems (7.Bxf6 vs 7.Bh4 in the QGD — a capture and a retreat, two
      // structures) while the book lists lines under only one of them. Ask
      // Maia, and treat that as a fork too.
      if (!ourMove && await _isStructuralFork(fen, path)) return false;
      // Otherwise the walk *would* stop here — but never silently: show the
      // position and let the user confirm, or keep setting up.
      await _openLeafConfirm(path, fen);
      return true;
    }

    if (ourMove) {
      final known = knowledge.chapterMovesAt(fen);
      if (known.length == 1) {
        final child = [...path, known.first];
        _setReach(child, reachOf(path));
        await _assignChapter(child, parent: path, ourChoice: true);
        _frontier.insert(0, child);
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
    final big = candidates
        .where((c) => (c.share ?? 0) >= chapterShare)
        .toList();
    if (big.length < 2) return false;
    final codes = big.map((c) => c.eco).where((e) => e != null).toSet();
    if (codes.length >= 2) return true;
    final captures = big.where((c) => c.san.contains('x')).length;
    return captures > 0 && captures < big.length;
  }

  /// Line roots the user asked to keep setting up past the book's end. Every
  /// position on or below such a root is asked as an ordinary question, with
  /// no more leaf confirmations, until the user presses Stop there.
  final List<List<String>> _manualRoots = [];

  /// Whether [path] is inside a line the user is setting up by hand.
  bool isManual(List<String> path) => _manualRoots.any(
    (r) =>
        r.length <= path.length &&
        List.generate(r.length, (i) => r[i] == path[i]).every((b) => b),
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
    );
    notifyListeners();
  }

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

  static String _label(List<String> moves) {
    final buf = StringBuffer();
    for (var i = 0; i < moves.length; i++) {
      if (i.isEven) buf.write('${i ~/ 2 + 1}.');
      buf.write(moves[i]);
      if (i < moves.length - 1) buf.write(' ');
    }
    return buf.toString();
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
    );
    notifyListeners();
  }

  /// Leaf confirmed: cut the chapter here and move on.
  Future<void> confirmLeaf() async {
    final step = _step;
    if (step == null || step.kind != PlanStepKind.confirmLeaf) return;
    _pushHistory();
    await _cutChapter(step.moves, reason: 'you chose to generate from here');
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

  /// Candidates whose on-demand engine run is in flight (SAN), for spinners.
  final Set<String> evaluating = {};

  /// Run the engine for one candidate that has no evaluation yet.
  Future<void> evaluateCandidate(String san) async {
    final step = _step;
    if (step == null || step.loading || evaluating.contains(san)) return;
    final cand = step.candidates.where((c) => c.san == san).firstOrNull;
    if (cand == null) return;
    final after = _fenAfter([...step.moves, san]);
    if (after == null) return;
    evaluating.add(san);
    notifyListeners();
    final result = await source.engineEval(after);
    evaluating.remove(san);
    final current = _step;
    if (current == null || current.moves != step.moves) {
      notifyListeners();
      return;
    }
    if (result != null) {
      _step = current.copyWith(
        candidates: [
          for (final c in current.candidates)
            c.san == san
                ? c.copyWith(
                    evalCp: result.cp,
                    evalDepth: result.depth,
                    evalSource: 'Stockfish',
                  )
                : c,
        ],
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

  Future<void> _openStep(List<String> path) async {
    final epoch = _epoch;
    final fen = _fenAfter(path)!;
    final ourMove = _isOurMove(fen);
    final kind = ourMove ? PlanStepKind.ourMove : PlanStepKind.theirMove;
    final name = await source.nameFor(path);
    _step = PlanStep(
      moves: path,
      kind: kind,
      fen: fen,
      candidates: const [],
      loading: true,
      positionName: name,
      preselected: const {},
      reachProb: reachOf(path),
    );
    notifyListeners();

    var candidates = await source.candidates(
      fen: fen,
      moves: path,
      ourMove: ourMove,
      elo: elo,
    );
    if (epoch != _epoch || _step == null || _step!.moves != path) return;

    candidates = _overlayKnowledge(candidates, fen, ourMove);
    final pre = <String>{};
    if (ourMove) {
      // One move at our own turn: the chapter's move if it has one, else the
      // user's most-played move here, else nothing.
      final inChapters = candidates.where((c) => c.inChapters);
      if (inChapters.isNotEmpty) {
        pre.add(inChapters.first.san);
      } else {
        // Their own most-played move, when they have played here enough.
        final own = candidates
            .where((c) => (c.ownGames ?? 0) >= 5 && (c.ownShare ?? 0) >= 0.4)
            .toList();
        if (own.isNotEmpty) pre.add(own.first.san);
      }
    } else {
      for (final c in candidates) {
        if ((c.share ?? 0) >= chapterShare) pre.add(c.san);
      }
    }
    _step = _step!.copyWith(
      candidates: candidates,
      loading: false,
      preselected: pre,
    );
    notifyListeners();
    // The question is on screen; now the slow parts land row by row: the
    // database first (all at once), then Stockfish for whatever it missed.
    unawaited(_fillEvals(path, epoch));
  }

  /// How many rows get database / engine evaluations per question.
  int dbFillLimit = 10;
  int engineFillLimit = 8;

  Future<void> _fillEvals(List<String> path, int epoch) async {
    final step = _step;
    if (step == null || step.moves != path) return;
    final targets = step.candidates.take(dbFillLimit).toList();
    await Future.wait(
      targets.map((c) async {
        final after = _fenAfter([...path, c.san]);
        if (after == null) return;
        final hit = await source.dbEval(after);
        if (hit == null || epoch != _epoch) return;
        _patchCandidate(
          path,
          c.san,
          (x) => x.copyWith(
            evalCp: hit.cp,
            evalDepth: hit.depth,
            evalSource: hit.source,
          ),
        );
      }),
    );
    if (epoch != _epoch) return;
    final missing = (_step?.moves == path ? _step!.candidates : const [])
        .where((c) => c.evalCp == null)
        .take(engineFillLimit)
        .map((c) => c.san)
        .toList();
    for (final san in missing) {
      if (epoch != _epoch || _step == null || _step!.moves != path) return;
      await evaluateCandidate(san);
    }
  }

  /// Replace one candidate of the current step (if still at [path]).
  void _patchCandidate(
    List<String> path,
    String san,
    PlanCandidate Function(PlanCandidate) update,
  ) {
    final current = _step;
    if (current == null || current.moves != path) return;
    _step = current.copyWith(
      candidates: [
        for (final c in current.candidates) c.san == san ? update(c) : c,
      ],
    );
    notifyListeners();
  }

  List<PlanCandidate> _overlayKnowledge(
    List<PlanCandidate> candidates,
    String fen,
    bool ourMove,
  ) {
    final chapterMoves = ourMove
        ? knowledge.chapterMovesAt(fen)
        : const <String>{};
    final out = <PlanCandidate>[];
    final seen = <String>{};
    for (final c in candidates) {
      final own = ourMove
          ? knowledge.ownMoveAt(fen, c.san)
          : knowledge.ownReplyAt(fen, c.san);
      out.add(
        c.copyWith(
          inChapters: chapterMoves.contains(c.san),
          ownShare: own?.share,
          ownGames: own?.games,
        ),
      );
      seen.add(c.san);
    }
    // A move the user plays that the sources did not list still deserves a row.
    for (final san in chapterMoves) {
      if (seen.add(san)) {
        final own = knowledge.ownMoveAt(fen, san);
        out.add(
          PlanCandidate(
            san: san,
            inChapters: true,
            ownShare: own?.share,
            ownGames: own?.games,
          ),
        );
      }
    }
    return out;
  }

  static String familyOf(String? bookName) {
    if (bookName == null || bookName.isEmpty) return 'Repertoire';
    final colon = bookName.indexOf(':');
    return (colon > 0 ? bookName.substring(0, colon) : bookName).trim();
  }

  /// The chapter [path] belongs to, creating the root chapter on first use.
  Future<PlanChapter> _chapterFor(List<String> path) async {
    final key = path.join(' ');
    final idx = _chapterOf[key];
    if (idx != null) return _chapters[idx];
    // Only the walk's root gets here without an assignment.
    final family = familyOf(await source.nameFor(path));
    final chapter = PlanChapter(
      name: family,
      family: family,
      moves: List.of(path),
    );
    _chapters.add(chapter);
    _chapterOf[key] = _chapters.length - 1;
    return chapter;
  }

  /// Decide whether [child] starts a new chapter or stays in its parent's.
  ///
  /// New chapter when the book names a *different family* below the child
  /// and — for an opponent's reply — the branch carries [chapterMass] of the
  /// games from the root. Our own choices (…e6 vs …c6) split by family alone:
  /// the user chose both systems.
  Future<void> _assignChapter(
    List<String> child, {
    required List<String> parent,
    required bool ourChoice,
  }) async {
    final parentChapter = await _chapterFor(parent);
    final parentIdx = _chapters.indexOf(parentChapter);
    final family = familyOf(await source.nameFor(child));
    final differs = family != parentChapter.family;
    final heavy = ourChoice || reachOf(child) >= chapterMass;
    if (differs && heavy) {
      final chapter = PlanChapter(
        name: family,
        family: family,
        moves: List.of(child),
      );
      _chapters.add(chapter);
      _chapterOf[child.join(' ')] = _chapters.length - 1;
    } else {
      _chapterOf[child.join(' ')] = parentIdx;
    }
  }

  /// The walk stops at [path]: record a build point in its chapter.
  Future<void> _cutChapter(
    List<String> path, {
    List<String> excludeReplies = const [],
    required String reason,
  }) async {
    final chapter = await _chapterFor(path);
    chapter.points.add(
      PlanBuildPoint(
        moves: List.of(path),
        excludeReplies: excludeReplies,
        reason: reason,
      ),
    );
  }

  /// Two chapters of the same family (rare: two of our systems inside one
  /// name) get the move that tells them apart appended.
  void _disambiguateNames() {
    final byName = <String, List<PlanChapter>>{};
    for (final c in _chapters) {
      byName.putIfAbsent(c.name, () => []).add(c);
    }
    for (final group in byName.values) {
      if (group.length < 2) continue;
      var prefix = List.of(group.first.moves);
      for (final c in group.skip(1)) {
        var n = 0;
        while (n < prefix.length &&
            n < c.moves.length &&
            prefix[n] == c.moves[n]) {
          n++;
        }
        prefix = prefix.sublist(0, n);
      }
      for (final c in group) {
        if (c.moves.length > prefix.length) {
          final ref = formatMoveReference(
            c.moves[prefix.length],
            prefix.length,
            rootWhiteToMove: true,
          );
          if (!c.name.contains(ref)) c.name = '${c.name} · $ref';
        }
      }
    }
    // Chapters that ended up with nothing to build (every branch moved into
    // another chapter) are dropped, and empty names are given something.
    _chapters.removeWhere((c) => c.points.isEmpty);
  }

  // ── Helpers ────────────────────────────────────────────────────────────

  bool _isOurMove(String fen) {
    final whiteToMove = fen.split(' ').elementAtOrNull(1) != 'b';
    return whiteToMove == isWhite;
  }

  static String? _fenAfter(List<String> path) {
    try {
      var pos = Chess.initial as Position;
      for (final san in path) {
        final next = playSanOrNullMove(pos, san);
        if (next == null) return null;
        pos = next;
      }
      return pos.fen;
    } catch (_) {
      return null;
    }
  }

  static String _ref(int ply) => 'move ${ply ~/ 2 + 1}';
}

/// Line extraction from a [BuildTree] after repertoire selection.
///
/// Walks the tree following `isRepertoireMove` flags at our-move nodes and all
/// children at opponent nodes to produce complete lines, gathering per-move
/// annotations on the way out.  Ports C's `extract_lines` from `repertoire.c`.
///
/// Extraction is a pure function of the valued tree — no engine, no network —
/// which is what lets the whole of Phase 3 be unit-tested on synthetic trees.
library;

import '../../models/build_tree_node.dart';
import '../../utils/movetext_builder.dart';
import 'export/move_annotation.dart';
import 'export/move_annotator.dart';
import 'fen_map.dart';
import 'generation_config.dart';
import '../../utils/fen_utils.dart';

// ── Coverage unit ────────────────────────────────────────────────────────

/// One our-move a line teaches, for [LinePruner]'s greedy set cover.
///
/// [key] is the *decision itself* — canonical FEN of the position faced, plus
/// the UCI we play in it. That is what a line actually teaches: "in this
/// position, play this move." Two lines share a key whenever they put the
/// user in front of the same choice, whether they got there by the same move
/// order or a different one.
///
/// It used to be the our-move projection prefix — the space-joined UCI of our
/// moves so far — which is order-*dependent*. That caught lines answering
/// different opponent deviations with the same replies, but not the far more
/// common case of two lines transposing into one another: same positions,
/// same answers, different move order, entirely different projection strings.
/// Both survived pruning and the user was shown two lines teaching one idea.
/// On a 7.6k-node Benko tree, 490 of 2099 extracted lines shared a decision
/// set with another and 701 were wholly contained in a single other line.
///
/// [value] is the reach probability of the position it was played in, scaled
/// up when the move is an only-move (large eval gap to the best non-selected
/// sibling).
class LineCoverageUnit {
  final String key;
  final double value;

  const LineCoverageUnit({required this.key, required this.value});
}

// ── Choice point ─────────────────────────────────────────────────────────

/// A position an exported line passes through, with everything needed to ask
/// "what if a human played something else here?".
///
/// The build tree cannot answer that on its own: our-move children are all
/// inside the eval-loss window (an engine-approved alternative is a different
/// move, not a refuted one), and a reply Maia ranks below the candidate floor
/// never becomes a child at all.  So the export records the *position* and
/// what the tree already knows about it, and the alternatives pass brings its
/// own move source — see `course/refutation_prober.dart`.
class LineChoice {
  /// Index in the line's `movesSan` of the move actually played here.
  final int moveIndex;

  /// The position the move was played from.  Doubles as the dedup key: two
  /// lines sharing a prefix share this choice, and everything on it is a
  /// property of the position rather than of the branch taken.
  final String fenBefore;

  final bool isOurMove;

  /// Best eval available to the side to move here, from *our* perspective and
  /// over the tree's children — the highest for us at an our-move node, the
  /// lowest at an opponent node.  Null when no child carries an eval, which
  /// is what makes "this alternative loses N centipawns" unanswerable.
  final int? bestEvalCpForUs;

  /// Moves the tree already holds at this position.  They are either exported
  /// elsewhere or known to be inside the eval window, so neither needs an
  /// engine probe to be explained.
  final List<String> knownUcis;

  const LineChoice({
    required this.moveIndex,
    required this.fenBefore,
    required this.isOurMove,
    required this.bestEvalCpForUs,
    required this.knownUcis,
  });
}

// ── Extracted line ───────────────────────────────────────────────────────

class ExtractedLine {
  final List<String> movesSan;
  final List<String> movesUci;
  final double probability;
  final PruneReason leafPruneReason;
  final int? leafPruneEvalCp;
  final String? openingName;
  final String? openingEco;
  final int? leafEvalCp;

  /// Position the line ends in.  Anything that wants to say more about a
  /// line's end than the tree recorded — an engine probe, a lookup — starts
  /// from here.
  final String? leafFen;

  final List<MoveAnnotation> moveAnnotations;
  final List<LineCoverageUnit> coverageUnits;

  /// Every position this line passes through, in move order.
  final List<LineChoice> choices;

  /// Set when the line was cut short because it transposed into a position
  /// whose continuation another line carries: that owning line's moves from
  /// the root to the position this line ends in (the same position by a
  /// different order).  The continuation is not repeated here — see
  /// [LineExtractor] for why.
  final List<String>? transposesInto;

  const ExtractedLine({
    required this.movesSan,
    required this.movesUci,
    required this.probability,
    this.leafPruneReason = PruneReason.none,
    this.leafPruneEvalCp,
    this.openingName,
    this.openingEco,
    this.leafEvalCp,
    this.leafFen,
    this.moveAnnotations = const [],
    this.coverageUnits = const [],
    this.choices = const [],
    this.transposesInto,
  });

  /// This line with its transposition pointer withdrawn: [transposesInto]
  /// cleared and [note] — the text [LineExtractor] appended for it — removed
  /// from the last annotation.
  ///
  /// Used when the move order the pointer named is not in the exported set,
  /// so the line ends plainly instead of naming something unfindable.
  ExtractedLine withoutTransposition(String note) => ExtractedLine(
    movesSan: movesSan,
    movesUci: movesUci,
    probability: probability,
    leafPruneReason: leafPruneReason,
    leafPruneEvalCp: leafPruneEvalCp,
    openingName: openingName,
    openingEco: openingEco,
    leafEvalCp: leafEvalCp,
    leafFen: leafFen,
    moveAnnotations: moveAnnotations.isEmpty
        ? moveAnnotations
        : [
            ...moveAnnotations.take(moveAnnotations.length - 1),
            moveAnnotations.last.withoutTransposition(note),
          ],
    coverageUnits: coverageUnits,
    choices: choices,
  );

  /// True when this line ends at a transposition rather than at a leaf of
  /// the tree.
  bool get isTransposition => transposesInto != null;

  /// The set of decisions this line teaches — "this position, this move" for
  /// every point where it is our turn. Order-free on purpose: two lines that
  /// transpose into each other teach the same thing and compare equal here.
  Set<String> get taughtDecisions => {for (final u in coverageUnits) u.key};
}

// ── Extractor ────────────────────────────────────────────────────────────

/// Walks the selected tree into lines.
///
/// **Transpositions are merged here, not only in the pruner.**  The build
/// keeps one expanded subtree per position and turns every other arrival
/// into a childless transposition leaf that resolves to it.  Walking that
/// subtree once per arrival — which is what following the leaves naively
/// does — hands the pruner the same continuation dressed in every move
/// order that reaches it (329 of 868 lines on a 31.8k-node Benko tree), and
/// whenever two of those move orders each teach something of their own the
/// pruner keeps both, so the reader sees one continuation twice.
///
/// Instead a cheap first pass walks the same traversal and, for every
/// position reached by more than one move order, picks an *owner*: the
/// arrival with the highest reach probability (ties to the earlier in tree
/// order, which is the more probable branch after `sortAllChildren`).  The
/// second pass emits the continuation under the owner only.  Every other
/// arrival ends at the shared position — after our reply when it is our
/// turn there, so no line ends on an unanswered opponent move — and records
/// the owner's move order in [ExtractedLine.transposesInto], which the last
/// move's annotation spells out as a note.  The pre-merge moves are still
/// taught, so the move order itself is still drilled; only the repeat is
/// gone.
///
/// Lines through positions reached one way only are untouched by this.
class LineExtractor {
  final TreeBuildConfig config;
  final FenMap? fenMap;

  LineExtractor({required this.config, this.fenMap})
    : _annotator = MoveAnnotator(
        playAsWhite: config.playAsWhite,
        maxEvalLossCp: config.maxEvalLossCp,
        postBook: config.isChessDbBook
            ? PostBookContinuation.chessDb
            : PostBookContinuation.engineAndMaia,
        movesFromPositionDatabase: config.isChessDbBook,
        bookMinGames: config.masterMinGames > 0 ? config.masterMinGames : 1,
      );

  /// Everything said *about* a move, as opposed to which moves a line holds.
  final MoveAnnotator _annotator;

  /// Per canonical position: the arrival that carries its continuation.
  /// Rebuilt by every [extract] call.
  Map<String, _Arrival> _owners = const {};

  /// Move numbering of the root position, for the transposition note.
  int _rootMoveNumber = 1;
  bool _rootWhiteToMove = true;

  /// Eval gaps beyond this add no extra only-move weight.
  static const int _sharpnessCapCp = 200;

  /// An our-move this far ahead of every alternative is effectively forced.
  ///

  /// Upper bound on lines one extraction will produce.  A safety valve
  /// against a pathological tree, not a tuning knob: a real 31.8k-node
  /// build yields a few hundred.  When it is hit, [wasTruncated] says so
  /// and the caller reports it — a silently shortened repertoire would read
  /// as complete.
  static const int kDefaultMaxLines = 50000;

  /// True when the last [extract] stopped at its line cap, dropping every
  /// branch the walk had not yet reached.
  bool get wasTruncated => _truncated;
  bool _truncated = false;

  /// How many times [extract] may hand ownership back and walk again before
  /// giving up.  Repairs are rare and each round fixes at least one position.
  static const int _maxOwnershipRepairs = 4;

  /// Every deferral the last traversal made: the contested position, the
  /// arrival that stopped there, and how it got there.
  List<({String key, BuildTreeNode node, List<String> movesSan, double reach})>
  _merges = [];

  /// Every move-order prefix the last traversal actually emitted, built up as
  /// each line is recorded rather than re-joined per repair round.
  ///
  /// Node identity cannot stand in for this.  The walk descends through
  /// `resolveTransposition(node).children`, so one node is reached under
  /// several move orders — and an owner whose own order never reached the
  /// output would still look "played" because somebody else's order walked
  /// its node, leaving a `Transposes to …` pointer aimed at a line that was
  /// never written.
  final Set<String> _playedMoveOrders = {};

  /// Extract complete repertoire lines from the tree.
  List<ExtractedLine> extract(
    BuildTree tree, {
    int maxLines = kDefaultMaxLines,
  }) {
    _truncated = false;
    _rootWhiteToMove = tree.root.isWhiteToMove;
    _rootMoveNumber = fullMoveNumber(tree.root.fen);
    _owners = {};
    _ownerDfs(
      node: tree.root,
      movesSan: <String>[],
      reach: 1.0,
      visited: <String>{},
    );
    // The owner pass explores paths this one will not: it never stops at a
    // merge, so it can hand a position's continuation to an arrival that the
    // extraction traversal cannot reach.  Walk, check that every deferral
    // actually landed somewhere, and give ownership back to the arrival that
    // deferred when it did not.  Each round strictly increases the number of
    // positions owned by an arrival this traversal reaches, so it converges;
    // the bound is a backstop against a pathological tree, and
    // [withdrawDanglingTranspositions] cleans up anything left.
    var lines = <ExtractedLine>[];
    for (var attempt = 0; ; attempt++) {
      lines = <ExtractedLine>[];
      _merges = [];
      _playedMoveOrders.clear();
      _extractDfs(
        node: tree.root,
        path: _LinePath(),
        lines: lines,
        maxLines: maxLines,
        reach: 1.0,
        visited: <String>{},
      );
      if (attempt >= _maxOwnershipRepairs) break;
      if (!_reassignUnreachableOwners()) break;
    }
    return lines;
  }

  /// Give ownership back to arrivals whose deferral led nowhere.
  ///
  /// Returns true when at least one owner changed, meaning the caller should
  /// walk again.
  bool _reassignUnreachableOwners() {
    if (_merges.isEmpty) return false;
    var changed = false;
    for (final m in _merges) {
      final owner = _owners[m.key];
      // Already ours, or the owner's move order really is in the output.
      if (owner == null || identical(owner.node, m.node)) continue;
      if (_playedMoveOrders.contains(owner.movesSan.join(' '))) continue;
      _owners[m.key] = _Arrival(m.node, m.reach, m.movesSan);
      changed = true;
    }
    return changed;
  }

  /// Every move-order prefix [lines] actually plays.
  static Set<String> _playedPrefixes(List<ExtractedLine> lines) {
    final played = <String>{};
    for (final line in lines) {
      final buffer = StringBuffer();
      for (var i = 0; i < line.movesSan.length; i++) {
        if (i > 0) buffer.write(' ');
        buffer.write(line.movesSan[i]);
        played.add(buffer.toString());
      }
    }
    return played;
  }

  /// First pass: the same traversal as [_extractDfs], recording for every
  /// position the arrival with the highest reach probability.  A position
  /// entered once is its own owner; one entered by several move orders gets
  /// the most probable of them.
  ///
  /// [movesSan] is the shared path list: pushed before and popped after each
  /// descent, and copied only where an [_Arrival] keeps it.
  void _ownerDfs({
    required BuildTreeNode node,
    required List<String> movesSan,
    required double reach,
    required Set<String> visited,
  }) {
    final resolved = resolveTransposition(node, fenMap);
    if (isTranspositionCycle(node, resolved, visited)) return;

    final key = enterFenPath(resolved, visited);
    final current = _owners[key];
    if (current == null || reach > current.reach) {
      _owners[key] = _Arrival(node, reach, List.unmodifiable(movesSan));
    }

    final isOurMove = node.isWhiteToMove == config.playAsWhite;
    if (isOurMove) {
      final selected = resolved.children
          .where((c) => c.isRepertoireMove)
          .firstOrNull;
      if (selected != null) {
        movesSan.add(selected.moveSan);
        _ownerDfs(
          node: selected,
          movesSan: movesSan,
          reach: reach,
          visited: visited,
        );
        movesSan.removeLast();
      }
    } else {
      for (final child in resolved.children) {
        if (!_exportable(child)) continue;
        movesSan.add(child.moveSan);
        _ownerDfs(
          node: child,
          movesSan: movesSan,
          reach: reach * child.moveProbability,
          visited: visited,
        );
        movesSan.removeLast();
      }
    }
    leaveFenPath(key, visited);
  }

  /// Opponent replies below the reach floor are not exported unless the
  /// coverage floor forced an answer for them.
  bool _exportable(BuildTreeNode child) {
    final covered =
        config.coverMinProb > 0.0 &&
        child.moveProbability >= config.coverMinProb;
    return covered || child.cumulativeProbability >= config.minProbability;
  }

  /// Whether this arrival at [resolved]'s position is the one that carries
  /// the continuation.  [node] is the arrival itself — a transposition leaf
  /// or the canonical node — so identity, not position, decides.
  bool _ownsContinuation(BuildTreeNode node, BuildTreeNode resolved) {
    final owner = _owners[canonicalizeFen(resolved.fen)];
    return owner == null || identical(owner.node, node);
  }

  /// How many transposition pointers the last
  /// [withdrawDanglingTranspositions] had to withdraw.
  int get danglingTranspositions => _danglingTranspositions;
  int _danglingTranspositions = 0;

  /// Withdraw every "Transposes to ..." pointer naming a move order that no
  /// line in [lines] actually plays.
  ///
  /// The pointer exists so the shared continuation is taught once rather than
  /// repeated under every move order that reaches it. Two things can leave it
  /// aimed at nothing: [LinePruner] dropping the owning line (it pins owners
  /// back, so what arrives here is the residue), and this extractor's two
  /// traversals disagreeing about a transposition cycle — [_ownerDfs] and
  /// [_extractDfs] carry independent `visited` sets, so a position whose owner
  /// path is cut in pass 2 can have both arrivals stop and its continuation
  /// emitted nowhere.
  ///
  /// Naming a line the reader cannot find is worse than a line that simply
  /// ends, so the claim is withdrawn rather than exported. Call after every
  /// filtering step, on the final set.
  List<ExtractedLine> withdrawDanglingTranspositions(
    List<ExtractedLine> lines,
  ) {
    _danglingTranspositions = 0;
    if (!lines.any((l) => l.transposesInto != null)) return lines;

    final played = _playedPrefixes(lines);

    final out = <ExtractedLine>[];
    for (final line in lines) {
      final target = line.transposesInto;
      // An empty target is the starting position, which is always present.
      if (target == null ||
          target.isEmpty ||
          played.contains(target.join(' '))) {
        out.add(line);
        continue;
      }
      _danglingTranspositions++;
      out.add(line.withoutTransposition(_transpositionNote(target)));
    }
    return out;
  }

  /// The note written on the last move of a line cut at a transposition.
  String _transpositionNote(List<String> ownerMoves) {
    if (ownerMoves.isEmpty) return 'Transposes to the starting position.';
    final text = buildNumberedMovetext(
      ownerMoves,
      startMoveNumber: _rootMoveNumber,
      whiteToMoveFirst: _rootWhiteToMove,
    );
    return 'Transposes to $text.';
  }

  /// The extraction traversal.  [path] is the one growing line shared by
  /// the whole walk: each descent pushes a ply and pops it on the way back,
  /// and [_emitLine] copies it when a line is finished.  Copying at every
  /// level instead — five lists per ply — was quadratic in depth per line,
  /// repeated for every repair round.
  void _extractDfs({
    required BuildTreeNode node,
    required _LinePath path,
    required List<ExtractedLine> lines,
    required int maxLines,
    required double reach,
    required Set<String> visited,
  }) {
    if (lines.length >= maxLines) {
      _truncated = true;
      return;
    }

    final resolved = resolveTransposition(node, fenMap);

    // Cycle guard: if following a transposition link re-enters a position
    // already on the current path, stop expanding and emit the line so far.
    final cycle = isTranspositionCycle(node, resolved, visited);

    final isOurMove = node.isWhiteToMove == config.playAsWhite;
    var pushedAny = false;

    // Another move order owns this position's continuation: stop here.  On
    // our turn the reply is still written — the owner carries the subtree
    // beyond it, but a line must not end with the opponent to move and us
    // with nothing to play.
    final merge =
        !cycle && path.isNotEmpty && !_ownsContinuation(node, resolved);
    if (merge) {
      // Remember which arrival deferred at which position, so [extract]'s
      // repair pass can hand ownership back here if the owner turns out to be
      // unreachable in this traversal.
      _merges.add((
        key: canonicalizeFen(resolved.fen),
        node: node,
        movesSan: List.unmodifiable(path.movesSan),
        reach: reach,
      ));
    }

    if (!cycle) {
      final key = enterFenPath(resolved, visited);
      if (isOurMove) {
        final selected = resolved.children
            .where((c) => c.isRepertoireMove)
            .firstOrNull;
        if (selected != null) {
          pushedAny = true;
          final gapCp = _annotator.leadOverAlternatives(resolved, selected);
          // Keyed by the position faced rather than the path taken to it, so
          // a transposition is recognised as the same decision.
          final decisionKey =
              '${canonicalizeFen(resolved.fen)}|${selected.moveUci}';
          path.push(
            san: selected.moveSan,
            uci: selected.moveUci,
            annotation: _annotator.annotateOurMove(selected, gapCp),
            choice: _choiceAt(resolved, path.length, isOurMove: true),
            unit: LineCoverageUnit(
              key: decisionKey,
              value:
                  selected.cumulativeProbability *
                  (1.0 + gapCp.clamp(0, _sharpnessCapCp) / 100.0),
            ),
          );
          if (merge) {
            _emitLine(
              leaf: selected,
              // A merged line is a stub: it teaches the move order and hands
              // over to the owner.  Its mass is the probability of *this*
              // path, never the node's `cumulativeProbability` — the build
              // sums every arrival into that, so when this arrival happens to
              // be the canonical node the stub would be credited with the
              // owner's mass too.
              probability: reach,
              path: path,
              lines: lines,
              // The owner's path to the *same* position this line ends in —
              // its reply here is ours too.
              transposesInto: [..._owners[key]!.movesSan, selected.moveSan],
            );
          } else {
            _extractDfs(
              node: selected,
              path: path,
              lines: lines,
              maxLines: maxLines,
              // Our own move does not change how likely the line is: we
              // always play it.  Same rule as [_ownerDfs].
              reach: reach,
              visited: visited,
            );
          }
          path.pop();
        }
      } else if (merge) {
        // We just moved into a position another line continues from.
        pushedAny = true;
        _emitLine(
          leaf: node,
          path: path,
          lines: lines,
          probability: reach,
          transposesInto: _owners[key]!.movesSan,
        );
      } else {
        for (final child in resolved.children) {
          // Coverage-floored children sit below the reach-probability floor
          // but carry a guaranteed answer — export their lines too.
          if (!_exportable(child)) continue;
          pushedAny = true;
          path.push(
            san: child.moveSan,
            uci: child.moveUci,
            annotation: _annotator.annotateOpponentMove(resolved, child),
            choice: _choiceAt(resolved, path.length, isOurMove: false),
          );
          _extractDfs(
            node: child,
            path: path,
            lines: lines,
            maxLines: maxLines,
            reach: reach * child.moveProbability,
            visited: visited,
          );
          path.pop();
        }
      }
      leaveFenPath(key, visited);
    }

    if (!pushedAny && path.isNotEmpty) {
      _emitLine(leaf: node, path: path, lines: lines);
    }
  }

  /// Record one finished line ending at [leaf].  A line cut at a
  /// transposition names the owning move order on its last move.
  void _emitLine({
    required BuildTreeNode leaf,
    required _LinePath path,
    required List<ExtractedLine> lines,
    List<String>? transposesInto,
    double? probability,
  }) {
    final (name: openingName, eco: openingEco) = _nearestOpening(leaf);

    // A copy: [path.annotations] keeps changing as the walk continues, and
    // the annotator hands the list back unchanged when there is no boundary.
    var annotations = _annotator.markTheoryBoundary(List.of(path.annotations));
    if (transposesInto != null && annotations.isNotEmpty) {
      annotations = [
        ...annotations.take(annotations.length - 1),
        annotations.last.withTransposition(
          transposesInto,
          _transpositionNote(transposesInto),
        ),
      ];
    }

    final prefix = StringBuffer();
    for (var i = 0; i < path.movesSan.length; i++) {
      if (i > 0) prefix.write(' ');
      prefix.write(path.movesSan[i]);
      _playedMoveOrders.add(prefix.toString());
    }
    lines.add(
      ExtractedLine(
        movesSan: List.unmodifiable(path.movesSan),
        movesUci: List.unmodifiable(path.movesUci),
        probability: probability ?? leaf.cumulativeProbability,
        leafPruneReason: leaf.pruneReason,
        leafPruneEvalCp: leaf.pruneEvalCp,
        openingName: openingName,
        openingEco: openingEco,
        leafEvalCp: leaf.engineEvalCp,
        leafFen: leaf.fen,
        moveAnnotations: annotations,
        coverageUnits: List.unmodifiable(path.coverageUnits),
        choices: List.unmodifiable(path.choices),
        transposesInto: transposesInto,
      ),
    );
  }

  /// The choice point at [position], where the move at [moveIndex] was played.
  LineChoice _choiceAt(
    BuildTreeNode position,
    int moveIndex, {
    required bool isOurMove,
  }) {
    int? best;
    for (final child in position.children) {
      if (!child.hasEngineEval) continue;
      final value = child.evalForUs(config.playAsWhite);
      if (best == null) {
        best = value;
      } else if (isOurMove ? value > best : value < best) {
        // Our node: the best we can do.  Opponent node: the best they can do,
        // which is the worst for us — the bar an alternative has to fall below
        // before it counts as a mistake by them.
        best = value;
      }
    }
    return LineChoice(
      moveIndex: moveIndex,
      fenBefore: position.fen,
      isOurMove: isOurMove,
      bestEvalCpForUs: best,
      knownUcis: [for (final child in position.children) child.moveUci],
    );
  }

  /// Nearest named opening at or above [node], walking toward the root.
  ({String? name, String? eco}) _nearestOpening(BuildTreeNode node) {
    for (BuildTreeNode? cur = node; cur != null; cur = cur.parent) {
      if (cur.openingName != null) {
        return (name: cur.openingName, eco: cur.openingEco);
      }
    }
    return (name: null, eco: null);
  }
}

/// The line under construction: parallel per-ply lists that grow and shrink
/// with the traversal.  Coverage units are recorded only at our moves, so
/// each push remembers whether it added one.
class _LinePath {
  final List<String> movesSan = [];
  final List<String> movesUci = [];
  final List<MoveAnnotation> annotations = [];
  final List<LineCoverageUnit> coverageUnits = [];
  final List<LineChoice> choices = [];
  final List<bool> _pushedUnit = [];

  int get length => movesSan.length;
  bool get isNotEmpty => movesSan.isNotEmpty;

  void push({
    required String san,
    required String uci,
    required MoveAnnotation annotation,
    required LineChoice choice,
    LineCoverageUnit? unit,
  }) {
    movesSan.add(san);
    movesUci.add(uci);
    annotations.add(annotation);
    choices.add(choice);
    if (unit != null) coverageUnits.add(unit);
    _pushedUnit.add(unit != null);
  }

  void pop() {
    movesSan.removeLast();
    movesUci.removeLast();
    annotations.removeLast();
    choices.removeLast();
    if (_pushedUnit.removeLast()) coverageUnits.removeLast();
  }
}

/// One way of reaching a position during extraction: the node entered (a
/// canonical node or a transposition leaf), the reach probability along that
/// path, and the moves that led there.
class _Arrival {
  final BuildTreeNode node;
  final double reach;
  final List<String> movesSan;

  const _Arrival(this.node, this.reach, this.movesSan);
}

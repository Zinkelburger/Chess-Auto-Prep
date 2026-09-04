/// Ranking of extracted lines by greedy weighted set cover, with a bar for
/// how *different* a line has to be to earn its own place in the book.
///
/// The unit of value is the decision a line teaches ([LineCoverageUnit],
/// keyed by the position faced plus the move we play in it), so two lines
/// share a unit whenever they put the user in front of the same choice —
/// whether they differ only in the opponent's moves or transpose into one
/// another by a different move order. Once one is selected the other's
/// marginal value is zero.
///
/// The greedy runs to exhaustion and keeps its whole order, because the
/// order *is* the answer to "which lines matter most": the Nth line is the
/// Nth most valuable new idea in the book. How many of them to keep is not
/// decided here and is not decided at build time — a build exports the
/// ranking, and the size is chosen afterwards against a live line count.
/// Asking for a coverage share before the build meant guessing with no
/// information, and baking the guess into the file.
///
/// ## Why "teaches something new" was not a high enough bar
///
/// Set cover admits a line the moment it carries one uncovered unit, and
/// measurement says that is far too generous. On the 40k-node Benko build,
/// exporting the whole ranking gave 519 lines of which the *median* one
/// shared 12 of its 14 plies with another kept line, had 6 of its 7
/// decisions taught elsewhere, and differed from its nearest twin only in
/// the final move or two — 90% of the book was a tail-only variant of
/// something else in the book. Every one of those lines is admissible under
/// "teaches something new" and none of them is a new *line*.
///
/// [LineDiversity] adds the missing bar, in two forms that bite on the same
/// failure from different sides:
///
/// - [LineDiversity.minNewShare] — against the book as a whole. At least
///   this share of a line's decisions must be ones no kept line teaches.
/// - [LineDiversity.maxOverlap] — against any single line. A cap on the
///   Jaccard of the two decision sets, which is the plain statement "differ
///   from every line already kept by more than one decision".
///
/// **Both count decisions; neither weighs them.** The obvious alternative —
/// require a line's uncovered *value* to be a fair share of its own total —
/// was tried and is structurally broken. A unit is worth the reach
/// probability of the position it is played in, so a line's value is
/// dominated by its first two or three decisions, which are precisely the
/// ones every sibling line shares. After the very first pick covers them,
/// every other line's remaining value is a rounding error against its own
/// total, and a 10% floor keeps 11 lines out of 753. The measurement is in
/// `test/tools/tune_diversity.dart`; the lesson is that reach-probability
/// value answers "how much does this line matter", not "how much of it is
/// new", and only the second question is about diversity.
///
/// Both are monotone over the greedy — the covered set only grows, and the
/// kept set with it — so a candidate that fails once fails forever, and it
/// is sound to exclude it on the spot rather than re-test it every round.
///
/// ## What happens to a line that fails the bar
///
/// Dropping it outright would lose a real answer: the line does teach a
/// decision nothing else teaches, it just is not worth a whole chapter entry
/// to say so. So a failed line is *folded* into the kept line it shares the
/// longest prefix with ([FoldedLine]), and the export writes it as a
/// sideline hanging off the move where the two part. The reader still sees
/// the reply and our answer to it; training just does not quiz a fourteenth
/// near-copy of the mainline. A line with no kept line to hang off — no
/// shared prefix, or a divergence too early for the sideline to be anything
/// but a second line in disguise — is dropped, and [LineSlice.droppedCount]
/// says how many.
library;

import 'generation_config.dart';
import 'line_extractor.dart';

/// How different a line must be from the book it is joining.
///
/// [off] restores the old behaviour exactly: everything that teaches a
/// decision no kept line teaches gets its own entry.
class LineDiversity {
  const LineDiversity({
    this.minNewShare = 0.0,
    this.maxOverlap = 1.0,
    this.maxFoldPlies = 6,
  });

  /// Share of a line's decisions that must be ones no kept line already
  /// teaches. 0 disables the floor.
  ///
  /// Counted, not value-weighted — see the library comment for why the
  /// value-weighted version does not work.
  final double minNewShare;

  /// Largest decision-set Jaccard a line may have with any line already
  /// kept. 1 disables the cap.
  ///
  /// The ladder is coarse because lines are short: for two seven-decision
  /// lines, sharing six of seven scores 0.75 and sharing five scores 0.56.
  /// So 0.7 means "differ by more than one decision" and 0.5 means "by more
  /// than two"; there is nothing in between to tune.
  final double maxOverlap;

  /// Longest sideline a fold may produce, in plies. Past this the folded
  /// line is not an "and if instead…" note, it is a second line written
  /// inside the first, so it is dropped instead.
  final int maxFoldPlies;

  /// The default bar: differ from every single kept line by more than one
  /// decision, and be at least a quarter new against the book as a whole.
  static const standard = LineDiversity(minNewShare: 0.25, maxOverlap: 0.7);

  /// Admit anything that teaches a decision no kept line teaches.
  static const off = LineDiversity();

  /// The bar this build asked for.
  factory LineDiversity.fromConfig(TreeBuildConfig config) => LineDiversity(
    minNewShare: config.lineMinNewShare,
    maxOverlap: config.lineMaxOverlap,
    maxFoldPlies: config.lineMaxFoldPlies,
  );

  bool get isActive => minNewShare > 0.0 || maxOverlap < 1.0;

  LineDiversity copyWith({
    double? minNewShare,
    double? maxOverlap,
    int? maxFoldPlies,
  }) => LineDiversity(
    minNewShare: minNewShare ?? this.minNewShare,
    maxOverlap: maxOverlap ?? this.maxOverlap,
    maxFoldPlies: maxFoldPlies ?? this.maxFoldPlies,
  );
}

/// A line the ranking folded into another rather than giving it an entry.
class FoldedLine {
  const FoldedLine({
    required this.line,
    required this.divergePly,
    required this.hostRank,
  });

  final ExtractedLine line;

  /// First ply at which [line] leaves its host — the point the export hangs
  /// the sideline off. Always `> 0` and `<= host.movesSan.length`.
  final int divergePly;

  /// The host's position in the greedy order, so a cut that does not reach
  /// the host does not render the fold either.
  final int hostRank;
}

/// A ranked line set: the greedy order plus the coverage each prefix reaches.
///
/// Cheap to hold and cheap to re-cut — [take] is the only thing a size
/// control needs to call, so a slider costs nothing after [LinePruner.rank]
/// has run once.
class LineSlice {
  LineSlice._(
    this._lines,
    this._picks,
    this._coveredMassAfter,
    this._answeredMassAfter,
    this._totalMass,
    this._folds,
    this.droppedCount,
  );

  final List<ExtractedLine> _lines;

  /// Indices into [_lines], best-first. Lines that teach nothing new never
  /// enter the greedy and so never appear here.
  final List<int> _picks;

  /// `_coveredMassAfter[i]` is the reach mass fully covered by the first
  /// `i + 1` ranked lines.
  final List<double> _coveredMassAfter;

  /// The same, also crediting lines folded into a host among those `i + 1`.
  final List<double> _answeredMassAfter;

  final double _totalMass;

  /// Folds by host index in [_lines]. Empty when diversity is off.
  final Map<int, List<FoldedLine>> _folds;

  /// Lines that failed the diversity bar and had nowhere to be folded, so
  /// they are not in the export at all.
  final int droppedCount;

  /// How many lines teach anything at all — the most a slice can hold.
  int get length => _picks.length;

  /// The ranked lines, best-first. Useful for showing what a cut includes.
  List<ExtractedLine> get ranked => [for (final i in _picks) _lines[i]];

  /// How many lines were folded into a kept line as a sideline instead of
  /// getting an entry of their own.
  int get foldedCount =>
      _folds.values.fold(0, (sum, list) => sum + list.length);

  /// Share (0..1) of reachable positions covered by the first [count] lines.
  ///
  /// Coverage is measured in reach mass rather than in the unit values that
  /// order the greedy. The values are dominated by the handful of
  /// near-certain decisions at the top of the tree, so 92% of value arrives
  /// after ~60 lines while 92% of the positions you actually reach needs
  /// ~300. The second number is the one that answers "how much of what I
  /// will face does this book cover".
  ///
  /// A folded line is deliberately *not* credited here: its decisions reach
  /// the file as a sideline, and a sideline is read, not drilled. So this is
  /// the share training will actually quiz you on, and with diversity on it
  /// tops out below 100% — the shortfall is what got folded away, which
  /// [answeredCoverageAt] adds back.
  double coverageAt(int count) => _shareAt(_coveredMassAfter, count);

  /// Share (0..1) of reachable positions the book *answers* — the mainlines
  /// plus the sidelines folded into them.
  ///
  /// The pair is the honest account of a cut: [coverageAt] is what you will
  /// be quizzed on, this is what you can look up. Without diversity the two
  /// are identical, because nothing is folded.
  ///
  /// A **lower bound**, deliberately. It credits kept lines and the folds
  /// hanging off them, and nothing else — so a line suppressed because every
  /// decision it teaches was already in the file is not counted, even though
  /// the reader can in fact look all of them up. On the Benko build that gap
  /// is 0.2%. Closing it exactly would mean tracking a second per-line
  /// coverage counter against the document rather than against the
  /// mainlines, and a headline number that errs downward is the right way
  /// for it to be wrong.
  double answeredCoverageAt(int count) => _shareAt(_answeredMassAfter, count);

  double _shareAt(List<double> massAfter, int count) {
    if (_totalMass <= 0.0 || massAfter.isEmpty) return 0.0;
    if (count <= 0) return 0.0;
    final i = count >= massAfter.length ? massAfter.length - 1 : count - 1;
    return (massAfter[i] / _totalMass).clamp(0.0, 1.0);
  }

  /// Fewest lines whose coverage reaches [share].
  int countForCoverage(double share) {
    if (_picks.isEmpty) return 0;
    final want = share.clamp(0.0, 1.0) * _totalMass;
    var take = 0;
    while (take < _picks.length && _coveredMassAfter[take] < want) {
      take++;
    }
    // Stop *at* the first pick that reaches the target, so take that one
    // too. This also makes a share of zero return one line rather than
    // none: a set with something to teach never comes back empty.
    if (take < _picks.length) take++;
    return take;
  }

  /// The best [count] lines, in the input's relative order.
  ///
  /// May return slightly more than [count]: a kept transposition stub drags
  /// its owner back in (see [LinePruner._pinTranspositionOwners]), because a
  /// book naming a move order it does not contain is the worse book.
  List<ExtractedLine> take(int count) {
    if (_picks.isEmpty) return const [];
    final keep = _keepFlags(count);
    return [
      for (var i = 0; i < _lines.length; i++)
        if (keep[i]) _lines[i],
    ];
  }

  /// The sidelines a cut of [count] lines carries, keyed by the host line's
  /// [LinePruner.lineKey].
  ///
  /// Only folds whose host survives the cut appear: a sideline whose
  /// mainline is gone has nothing to hang off. A folded line that the
  /// transposition pinning pulled back in as an entry of its own is dropped
  /// from here too, so nothing is written twice.
  Map<String, List<FoldedLine>> foldsFor(int count) {
    if (_folds.isEmpty || _picks.isEmpty) return const {};
    final keep = _keepFlags(count);
    final keptKeys = {
      for (var i = 0; i < _lines.length; i++)
        if (keep[i]) LinePruner.lineKey(_lines[i].movesSan),
    };
    final out = <String, List<FoldedLine>>{};
    for (final entry in _folds.entries) {
      if (!keep[entry.key]) continue;
      final host = LinePruner.lineKey(_lines[entry.key].movesSan);
      for (final fold in entry.value) {
        if (keptKeys.contains(LinePruner.lineKey(fold.line.movesSan))) continue;
        (out[host] ??= []).add(fold);
      }
    }
    return out;
  }

  /// Every line that teaches something new and cleared the diversity bar.
  List<ExtractedLine> get all => take(_picks.length);

  /// Every input line's key, whether it was ranked, folded, or dropped for
  /// teaching nothing.
  ///
  /// A cut drops everything it does not keep, and that includes the lines
  /// that never entered the ranking at all — a file written by an earlier
  /// build still holds them, and a control offering to trim the file has to
  /// know they are on the table.
  List<String> get everyLineKey => [
    for (final line in _lines) LinePruner.lineKey(line.movesSan),
  ];

  List<bool> _keepFlags(int count) {
    final n = count.clamp(1, _picks.length);
    final keep = List<bool>.filled(_lines.length, false);
    for (final i in _picks.take(n)) {
      keep[i] = true;
    }
    LinePruner._pinTranspositionOwners(_lines, _picks, keep);
    return keep;
  }
}

class LinePruner {
  LinePruner._();

  /// A line's identity: its SAN moves joined by spaces. The same rule
  /// `RepertoireSlicer` and `GenerationRequest` use, so a fold can be matched
  /// to the entry it hangs off.
  static String lineKey(List<String> moves) => moves.join(' ');

  /// Rank [lines] by greedy weighted set cover over the decisions they teach,
  /// admitting only those that clear [diversity].
  ///
  /// Lines with nothing to teach are ranked out entirely — they only ever
  /// repeat a decision another line already carries, so there is nothing to
  /// lose by dropping them and no reason to offer keeping them.
  static LineSlice rank(
    List<ExtractedLine> lines, {
    LineDiversity diversity = LineDiversity.off,
  }) {
    if (lines.length <= 1) {
      return LineSlice._(
        lines,
        [for (var i = 0; i < lines.length; i++) i],
        [for (final l in lines) l.probability],
        [for (final l in lines) l.probability],
        lines.isEmpty ? 0.0 : lines.first.probability,
        const {},
        0,
      );
    }

    // Intern unit keys to ints so the greedy loop hashes ints, not
    // position-and-move strings. Deduped per line: the extractor's path
    // guard already makes a repeat impossible, and relying on that here
    // means the overlap maths can trust `ids.length` as a set size.
    final unitIdByKey = <String, int>{};
    final lineUnitIds = <List<int>>[];
    final lineUnitValues = <List<double>>[];
    for (var i = 0; i < lines.length; i++) {
      final byId = <int, double>{};
      for (final unit in lines[i].coverageUnits) {
        final id = unitIdByKey.putIfAbsent(unit.key, () => unitIdByKey.length);
        final seen = byId[id];
        if (seen == null || unit.value > seen) byId[id] = unit.value;
      }
      lineUnitIds.add(byId.keys.toList(growable: false));
      lineUnitValues.add(byId.values.toList(growable: false));
    }

    final covered = List<bool>.filled(unitIdByKey.length, false);
    // Decisions the *document* carries: a kept line's, and a folded line's
    // too, because a sideline is in the file even though it is not drilled.
    // [covered] cannot do this job — it drives the marginal value the greedy
    // ranks by, and crediting a sideline there would let a fold pay for a
    // mainline.
    final inFile = List<bool>.filled(unitIdByKey.length, false);
    final chosen = List<bool>.filled(lines.length, false);
    // Out of the running: either folded, or suppressed for teaching nothing
    // the file does not already say. Kept apart from [chosen] because the
    // overlap test asks "which lines are actually mainlines", and neither of
    // these is one.
    final excluded = List<bool>.filled(lines.length, false);
    // The subset of [excluded] worth writing as a sideline.
    final foldCandidate = List<bool>.filled(lines.length, false);
    // Marginal values only shrink as coverage grows, so a line whose cached
    // bound trails the current round's best can be skipped unrecomputed.
    final upperBound = List<double>.filled(lines.length, double.infinity);

    // A line is "covered" once every decision in it is taught by something
    // already kept.
    final uncoveredLeft = [for (final ids in lineUnitIds) ids.length];
    final linesByUnit = List.generate(unitIdByKey.length, (_) => <int>[]);
    for (var i = 0; i < lineUnitIds.length; i++) {
      for (final id in lineUnitIds[i]) {
        linesByUnit[id].add(i);
      }
    }
    var totalMass = 0.0;
    for (var i = 0; i < lines.length; i++) {
      if (uncoveredLeft[i] > 0) totalMass += lines[i].probability;
    }

    // Run the greedy to exhaustion, recording after each pick how much reach
    // mass is *fully* covered by the picks so far, and which pick did it —
    // the fold accounting below needs to know whether a folded line was
    // already paid for by a mainline.
    final picks = <int>[];
    final coveredMassAfter = <double>[];
    final coveredAtRank = List<int?>.filled(lines.length, null);
    var coveredMass = 0.0;
    while (true) {
      var bestIdx = -1;
      var bestValue = 0.0;
      for (var i = 0; i < lines.length; i++) {
        if (chosen[i] || excluded[i] || upperBound[i] <= bestValue) continue;
        var marginal = 0.0;
        final ids = lineUnitIds[i];
        final values = lineUnitValues[i];
        for (var j = 0; j < ids.length; j++) {
          if (!covered[ids[j]]) marginal += values[j];
        }
        upperBound[i] = marginal;
        if (marginal > bestValue) {
          bestValue = marginal;
          bestIdx = i;
        }
      }
      if (bestIdx < 0) break;

      // Everything this line teaches is already in the document. Marginal
      // value is measured against the mainlines alone, so a line folded away
      // leaves its decisions *uncovered* — and without this check each of its
      // near-identical siblings wins a round with that same decision and is
      // folded in turn, writing one sideline seven times. Suppressing them is
      // the rule the greedy already applies to a line with nothing to teach;
      // it just has to count sidelines as teaching.
      if (diversity.isActive && _allInFile(lineUnitIds[bestIdx], inFile)) {
        excluded[bestIdx] = true;
        continue;
      }

      // The winner is the only candidate worth testing: if it fails, it can
      // never pass later, so excluding it and re-running the round both
      // finds the next-best line and leaves the hot loop above untouched.
      if (diversity.isActive &&
          !_clearsBar(
            bestIdx,
            diversity: diversity,
            covered: covered,
            lineUnitIds: lineUnitIds,
            linesByUnit: linesByUnit,
            chosen: chosen,
          )) {
        excluded[bestIdx] = true;
        foldCandidate[bestIdx] = true;
        for (final id in lineUnitIds[bestIdx]) {
          inFile[id] = true;
        }
        continue;
      }

      chosen[bestIdx] = true;
      picks.add(bestIdx);
      for (final id in lineUnitIds[bestIdx]) {
        inFile[id] = true;
        if (covered[id]) continue;
        covered[id] = true;
        for (final line in linesByUnit[id]) {
          if (--uncoveredLeft[line] == 0) {
            coveredMass += lines[line].probability;
            coveredAtRank[line] = picks.length - 1;
          }
        }
      }
      coveredMassAfter.add(coveredMass);
    }

    final (folds, dropped) = _foldRejected(
      lines,
      picks,
      foldCandidate,
      diversity.maxFoldPlies,
    );

    return LineSlice._(
      lines,
      picks,
      coveredMassAfter,
      _answeredMass(lines, coveredMassAfter, coveredAtRank, folds),
      totalMass,
      folds,
      dropped,
    );
  }

  static bool _allInFile(List<int> ids, List<bool> inFile) {
    for (final id in ids) {
      if (!inFile[id]) return false;
    }
    return true;
  }

  /// [coveredMassAfter] with each folded line's mass moved forward to the
  /// rank of the host that carries it.
  ///
  /// A folded line is fully answered the moment its host is kept: everything
  /// before the divergence is the host's own move order, and everything after
  /// it is written out in the sideline. It may *also* become covered later by
  /// mainlines alone, which is what [coveredAtRank] is for — the mass is
  /// added over the ranks where the fold is the only thing paying for it, and
  /// nowhere else, so nothing is counted twice.
  static List<double> _answeredMass(
    List<ExtractedLine> lines,
    List<double> coveredMassAfter,
    List<int?> coveredAtRank,
    Map<int, List<FoldedLine>> folds,
  ) {
    if (folds.isEmpty) return coveredMassAfter;
    final indexOf = <ExtractedLine, int>{
      for (var i = 0; i < lines.length; i++) lines[i]: i,
    };
    final n = coveredMassAfter.length;
    final delta = List<double>.filled(n + 1, 0.0);
    for (final list in folds.values) {
      for (final fold in list) {
        final index = indexOf[fold.line];
        if (index == null) continue;
        final alreadyAt = coveredAtRank[index];
        final end = alreadyAt ?? n;
        final start = alreadyAt == null || fold.hostRank < alreadyAt
            ? fold.hostRank
            : alreadyAt;
        if (start >= end || start >= n) continue;
        delta[start] += lines[index].probability;
        delta[end] -= lines[index].probability;
      }
    }
    final out = List<double>.filled(n, 0.0);
    var running = 0.0;
    for (var i = 0; i < n; i++) {
      running += delta[i];
      out[i] = coveredMassAfter[i] + running;
    }
    return out;
  }

  /// Whether the line at [index] is different enough from what is already
  /// kept to deserve an entry.
  ///
  /// Both tests are cheap because they only ever run on a round's winner:
  /// at most one call per line over the whole greedy.
  static bool _clearsBar(
    int index, {
    required LineDiversity diversity,
    required List<bool> covered,
    required List<List<int>> lineUnitIds,
    required List<List<int>> linesByUnit,
    required List<bool> chosen,
  }) {
    final ids = lineUnitIds[index];
    if (ids.isEmpty) return true;

    if (diversity.minNewShare > 0.0) {
      var fresh = 0;
      for (final id in ids) {
        if (!covered[id]) fresh++;
      }
      if (fresh < diversity.minNewShare * ids.length) return false;
    }
    if (diversity.maxOverlap >= 1.0) return true;

    // Intersection sizes against every kept line that shares at least one
    // decision, reached through the unit index rather than by scanning the
    // kept set — most kept lines share nothing with this one.
    final shared = <int, int>{};
    for (final id in ids) {
      for (final other in linesByUnit[id]) {
        if (other == index || !chosen[other]) continue;
        shared[other] = (shared[other] ?? 0) + 1;
      }
    }
    for (final entry in shared.entries) {
      final union = ids.length + lineUnitIds[entry.key].length - entry.value;
      if (union > 0 && entry.value / union > diversity.maxOverlap) return false;
    }
    return true;
  }

  /// Attach every rejected line to the kept line it parts from latest, and
  /// count the ones with nowhere to go.
  ///
  /// The host is chosen by longest shared move prefix rather than by decision
  /// overlap: a sideline has to hang off a move, and the move it hangs off is
  /// the one where the two orders actually part. Ties go to the better-ranked
  /// host, so a fold lands on the more important of two equally close lines.
  static (Map<int, List<FoldedLine>>, int) _foldRejected(
    List<ExtractedLine> lines,
    List<int> picks,
    List<bool> foldCandidate,
    int maxFoldPlies,
  ) {
    final folds = <int, List<FoldedLine>>{};
    var dropped = 0;
    for (var i = 0; i < lines.length; i++) {
      if (!foldCandidate[i]) continue;
      final moves = lines[i].movesSan;
      var bestHost = -1;
      var bestRank = -1;
      var bestPrefix = 0;
      for (var rank = 0; rank < picks.length; rank++) {
        final shared = _sharedPrefix(moves, lines[picks[rank]].movesSan);
        if (shared > bestPrefix) {
          bestPrefix = shared;
          bestHost = picks[rank];
          bestRank = rank;
        }
      }
      // Nothing to hang it off, or the "sideline" would be a whole line of
      // its own written inside another. Either way it does not belong in the
      // export as a note.
      if (bestHost < 0 ||
          bestPrefix == 0 ||
          bestPrefix >= moves.length ||
          moves.length - bestPrefix > maxFoldPlies) {
        dropped++;
        continue;
      }
      (folds[bestHost] ??= []).add(
        FoldedLine(line: lines[i], divergePly: bestPrefix, hostRank: bestRank),
      );
    }
    // Most likely first, so a host carrying several folds reads in the order
    // the opponent's tries actually turn up.
    for (final list in folds.values) {
      list.sort((a, b) => b.line.probability.compareTo(a.line.probability));
    }
    return (folds, dropped);
  }

  static int _sharedPrefix(List<String> a, List<String> b) {
    final limit = a.length < b.length ? a.length : b.length;
    var i = 0;
    while (i < limit && a[i] == b[i]) {
      i++;
    }
    return i;
  }

  /// Pull back any line whose continuation a *kept* transposition stub points
  /// at.
  ///
  /// A stub ends with "Transposes to 1. d4 ..." and deliberately does not
  /// repeat the continuation — the owning move order carries it. The greedy
  /// scores the two independently, so with `coverageTarget < 1.0` the prefix
  /// can keep the stub and drop the owner. That leaves the book naming a move
  /// order it does not contain, and the shared continuation taught nowhere at
  /// all.
  ///
  /// Pinning can push the result past [prune]'s `targetCount` cap. That is
  /// the intended trade: an owner teaches strictly more than the stub that
  /// references it, so honouring the cap by leaving a dangling reference
  /// would be the worse book. For the same reason it outranks the diversity
  /// bar: an owner rejected as too similar still comes back if a kept stub
  /// names it.
  ///
  /// Iterates to a fixed point — a pinned owner may itself be a stub for a
  /// further transposition. Each pass can only set flags, never clear them,
  /// so the loop terminates in at most [lines] rounds.
  static void _pinTranspositionOwners(
    List<ExtractedLine> lines,
    List<int> picks,
    List<bool> keep,
  ) {
    var changed = true;
    while (changed) {
      changed = false;
      for (var i = 0; i < lines.length; i++) {
        if (!keep[i]) continue;
        final target = lines[i].transposesInto;
        if (target == null) continue;
        if (_isCarriedBy(lines, keep, target, exclude: i)) continue;
        final owner = _ownerIndexFor(lines, picks, target, exclude: i);
        // No owner anywhere in the input: the note is dangling on arrival and
        // there is nothing here to pin. `stripDanglingTranspositions` drops
        // the claim rather than letting the export make it.
        if (owner == null) continue;
        keep[owner] = true;
        changed = true;
      }
    }
  }

  /// Whether some kept line other than [exclude] plays [target]'s move order.
  static bool _isCarriedBy(
    List<ExtractedLine> lines,
    List<bool> keep,
    List<String> target, {
    required int exclude,
  }) {
    for (var i = 0; i < lines.length; i++) {
      if (i == exclude || !keep[i]) continue;
      if (_startsWith(lines[i].movesSan, target)) return true;
    }
    return false;
  }

  /// The best line playing [target]'s move order: greedy order first, so the
  /// owner pulled back in is the one that teaches the most.
  static int? _ownerIndexFor(
    List<ExtractedLine> lines,
    List<int> picks,
    List<String> target, {
    required int exclude,
  }) {
    for (final i in picks) {
      if (i == exclude) continue;
      if (_startsWith(lines[i].movesSan, target)) return i;
    }
    // A line that teaches nothing new never enters the greedy, but it can
    // still be the only carrier of a move order.
    for (var i = 0; i < lines.length; i++) {
      if (i == exclude) continue;
      if (_startsWith(lines[i].movesSan, target)) return i;
    }
    return null;
  }

  static bool _startsWith(List<String> moves, List<String> prefix) {
    if (prefix.length > moves.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (moves[i] != prefix[i]) return false;
    }
    return true;
  }
}

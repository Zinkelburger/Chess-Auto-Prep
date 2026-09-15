/// A reversible teaching layer over the selected policy. No engine calls,
/// changed moves, or changes to the search value. Full move-order prefixes
/// identify decisions, so different repetition histories never merge.
library;

import 'dart:collection';

import '../../utils/fen_utils.dart';
import 'export/move_annotation.dart';
import 'export/pgn_game_writer.dart';
import 'line_extractor.dart';

/// One drill: the stretch of [line] from move index [start] to [end]
/// (inclusive) in which every one of our moves is quizzed.
class TrainingExercise {
  const TrainingExercise({
    required this.line,
    required this.start,
    required this.end,
    required this.decisions,
    required this.quietBoundary,
    required this.key,
  });

  final ExtractedLine line;

  /// First and last quizzed move index in [line].
  final int start, end;

  /// Decision keys — full move-order prefixes ending on our move — that this
  /// exercise teaches.
  final Set<String> decisions;

  /// True when the exercise ends on a quiet move pair; false when it ends at
  /// the search frontier, where the continuation may still need calculation.
  final bool quietBoundary;

  /// Identity: the start index plus the key of the final decision.
  final String key;

  int get ownMoves => decisions.length;
  List<String> get quizMoves => line.movesSan.sublist(start, end + 1);
}

/// Exercises in study order with the running coverage each prefix reaches.
class TrainingLinePlan {
  TrainingLinePlan._(
    this.exercises,
    this._coveredAfter,
    this._newAfter,
    this._workAfter,
    this.totalDecisions,
    this.unansweredFrontierMass,
  );

  final List<TrainingExercise> exercises;
  final List<double> _coveredAfter;
  final List<int> _newAfter, _workAfter;
  final int totalDecisions;

  /// Probability mass ending on an opponent move with no prepared answer.
  /// Separate from how much of the *existing* preparation is studied.
  final double unansweredFrontierMass;

  int _index(int count) => count.clamp(0, exercises.length);

  /// Share of decision weight the first [count] exercises teach.
  double coverageAt(int count) => _coveredAfter[_index(count)];

  /// Distinct decisions the first [count] exercises teach.
  int decisionsAt(int count) => _newAfter[_index(count)];

  /// Our moves quizzed across the first [count] exercises.
  int practicedMovesAt(int count) => _workAfter[_index(count)];

  /// A companion PGN with the whole source line for context/reference and
  /// the existing trainer's start/end markers delimiting the exercise.
  String toPgn({
    required int count,
    required String startFen,
    required bool playAsWhite,
    required String name,
    required String searchLabel,
  }) {
    final out = StringBuffer();
    for (var i = 0; i < _index(count); i++) {
      final e = exercises[i];
      final annotations = List<MoveAnnotation>.generate(
        e.line.movesSan.length,
        (j) => j < e.line.moveAnnotations.length
            ? e.line.moveAnnotations[j]
            : MoveAnnotation.none,
      );
      annotations[e.start] = annotations[e.start].withNote(
        '[%tstart] Exercise starts here.',
      );
      annotations[e.end] = annotations[e.end].withNote(
        '[%tend] Exercise ends here. ${e.quietBoundary ? 'Quiet move pair; this is a study boundary, not a tactical proof.' : 'Search frontier: the continuation may still require calculation.'} Later moves are reference only.',
      );
      out.writeln(
        writePgnGame(
          PgnGameSpec(
            headers: {
              'Event': '$name — exercise ${i + 1}',
              'White': playAsWhite ? 'Repertoire' : 'Opponent',
              'Black': playAsWhite ? 'Opponent' : 'Repertoire',
              'Result': '*',
              'Search': searchLabel,
              'ExerciseMoves': '${e.ownMoves}',
            },
            movesSan: e.line.movesSan,
            annotations: annotations,
            startFen: startFen,
            rootWhiteToMove: isWhiteToMove(startFen),
            startMoveNumber: fullMoveNumber(startFen),
            leadingComment:
                'Study copy. Earlier moves are context; train only between the markers. The original repertoire remains the full reference.',
          ),
          detail: MoveAnnotationDetail.full,
        ),
      );
    }
    return out.toString();
  }
}

/// A candidate exercise's slot in the greedy ranking.
typedef _Ranked = ({int index, double score});

/// Cuts extracted lines into exercises and orders them so each next
/// exercise teaches the most not-yet-covered decision weight per move
/// practised.
class TrainingLinePlanner {
  /// A move that captures, checks, mates or promotes is not a quiet stopping
  /// point.
  static final RegExp _forcingMove = RegExp(r'[x+#=]');

  /// Shorter practice units reduce repeated work; their length is a study
  /// preference, not a claim about a universal human memory capacity.
  static TrainingLinePlan build(
    List<ExtractedLine> input, {
    required bool rootWhiteToMove,
    required bool playAsWhite,
    int targetOwnMoves = 4,
    bool reduceRepetition = true,
  }) {
    if (targetOwnMoves < 1) throw ArgumentError.value(targetOwnMoves);
    final lines = _uniqueByProbability(input);
    final weights = <String, double>{};
    final candidates = <String, TrainingExercise>{};
    var unanswered = 0.0;
    for (final line in lines) {
      final endsUnanswered = _collectExercises(
        line,
        rootWhiteToMove: rootWhiteToMove,
        playAsWhite: playAsWhite,
        targetOwnMoves: targetOwnMoves,
        weights: weights,
        candidates: candidates,
      );
      if (endsUnanswered) unanswered += line.probability;
    }
    final choices = candidates.values.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return _greedyOrder(
      choices,
      weights: weights,
      unansweredFrontierMass: unanswered.clamp(0.0, 1.0),
      reduceRepetition: reduceRepetition,
    );
  }

  /// Distinct lines by move order, most probable first; ties by move text
  /// so the plan is deterministic.
  static List<ExtractedLine> _uniqueByProbability(List<ExtractedLine> input) {
    final unique = <String, ExtractedLine>{};
    for (final line in input) {
      if (!line.probability.isFinite || line.probability < 0) {
        throw ArgumentError('Invalid line probability');
      }
      unique.putIfAbsent(line.movesUci.join(' '), () => line);
    }
    return unique.values.toList()..sort((a, b) {
      final p = b.probability.compareTo(a.probability);
      return p != 0 ? p : a.movesUci.join(' ').compareTo(b.movesUci.join(' '));
    });
  }

  /// Add [line]'s decision weights to [weights] and its candidate exercises
  /// to [candidates] (first line to propose a key wins). Returns true when
  /// the line ends on an opponent move with no prepared answer.
  static bool _collectExercises(
    ExtractedLine line, {
    required bool rootWhiteToMove,
    required bool playAsWhite,
    required int targetOwnMoves,
    required Map<String, double> weights,
    required Map<String, TrainingExercise> candidates,
  }) {
    final ours = <int>[];
    final keys = <int, String>{};
    final path = <String>[];
    for (var i = 0; i < line.movesSan.length; i++) {
      path.add(i < line.movesUci.length ? line.movesUci[i] : line.movesSan[i]);
      if ((i.isEven ? rootWhiteToMove : !rootWhiteToMove) != playAsWhite) {
        continue;
      }
      final key = path.join(' ');
      keys[i] = key;
      ours.add(i);
      weights[key] = (weights[key] ?? 0) + line.probability;
    }
    for (var first = 0; first < ours.length;) {
      var last = (first + targetOwnMoves - 1).clamp(first, ours.length - 1);
      // Never stop between an opponent's move and our prepared response.
      // Continue through checks/captures/promotions while this tree has a
      // continuation. If it has none, call the boundary a frontier.
      while (last < ours.length - 1 && !_quietPair(line.movesSan, ours[last])) {
        last++;
      }
      final start = ours[first], end = ours[last];
      final key = '$start|${keys[end]}';
      candidates.putIfAbsent(
        key,
        () => TrainingExercise(
          line: line,
          start: start,
          end: end,
          key: key,
          decisions: {for (var j = first; j <= last; j++) keys[ours[j]]!},
          quietBoundary: _quietPair(line.movesSan, end),
        ),
      );
      first = last + 1;
    }
    return line.movesSan.isNotEmpty &&
        !line.leafTerminal &&
        (ours.isEmpty || ours.last != line.movesSan.length - 1);
  }

  /// Greedy order by uncovered weight per practised move.
  ///
  /// Prefixes already covered by earlier exercises become context. Scores
  /// can therefore rise as an exercise gets shorter. Refresh only candidates
  /// sharing newly learned decisions; do not reuse stale upper bounds.
  static TrainingLinePlan _greedyOrder(
    List<TrainingExercise> choices, {
    required Map<String, double> weights,
    required double unansweredFrontierMass,
    required bool reduceRepetition,
  }) {
    int compare(_Ranked a, _Ranked b) {
      final score = b.score.compareTo(a.score);
      return score != 0 ? score : a.index.compareTo(b.index);
    }

    final pending = SplayTreeSet<_Ranked>(compare);
    final entries = List<_Ranked?>.filled(choices.length, null);
    final used = List<bool>.filled(choices.length, false);
    final decisions = [for (final e in choices) e.decisions.toList()];
    final affectedBy = <String, List<int>>{};
    for (var i = 0; i < choices.length; i++) {
      for (final key in decisions[i]) {
        (affectedBy[key] ??= []).add(i);
      }
    }
    final covered = <String>{};
    int skipPrefix(int i) => decisions[i].takeWhile(covered.contains).length;
    void rank(int i) {
      final previous = entries[i];
      if (previous != null) pending.remove(previous);
      entries[i] = null;
      if (used[i]) return;
      final gain = decisions[i]
          .where((k) => !covered.contains(k))
          .fold(0.0, (a, k) => a + weights[k]!);
      if (gain <= 0) return;
      final cost = decisions[i].length - skipPrefix(i);
      final entry = (index: i, score: gain / (reduceRepetition ? cost : 1));
      entries[i] = entry;
      pending.add(entry);
    }

    for (var i = 0; i < choices.length; i++) {
      rank(i);
    }
    final order = <TrainingExercise>[];
    final coverage = [0.0];
    final newCount = [0], work = [0];
    final total = weights.values.fold(0.0, (a, b) => a + b);
    var mass = 0.0;
    while (pending.isNotEmpty) {
      final next = pending.first;
      pending.remove(next);
      entries[next.index] = null;
      used[next.index] = true;
      final source = choices[next.index];
      final skip = skipPrefix(next.index);
      final e = TrainingExercise(
        line: source.line,
        start: source.start + 2 * skip,
        end: source.end,
        decisions: decisions[next.index].skip(skip).toSet(),
        quietBoundary: source.quietBoundary,
        key: source.key,
      );
      order.add(e);
      final affected = <int>{};
      for (final key in e.decisions) {
        if (covered.add(key)) {
          mass += weights[key]!;
          affected.addAll(affectedBy[key]!);
        }
      }
      for (final i in affected) {
        rank(i);
      }
      coverage.add(total > 0 ? (mass / total).clamp(0.0, 1.0) : 0);
      newCount.add(covered.length);
      work.add(work.last + e.ownMoves);
    }
    return TrainingLinePlan._(
      List.unmodifiable(order),
      coverage,
      newCount,
      work,
      weights.length,
      unansweredFrontierMass,
    );
  }

  /// True when the move at [end] and the one before it are both quiet.
  static bool _quietPair(List<String> moves, int end) {
    bool quiet(String move) => !_forcingMove.hasMatch(move);
    return quiet(moves[end]) && (end == 0 || quiet(moves[end - 1]));
  }
}

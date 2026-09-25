/// One line being drilled: which move is on the board, what the lesson is
/// waiting for, and what the user got wrong. A value; the owner holding it
/// supplies the clock.
///
/// A line is taught in up to three passes:
///
/// 1. **Walkthrough** — only for a line never trained. Each of the user's
///    moves is shown on the board and waits for Next; then it is taken back
///    and asked for at once. A wrong answer is corrected and asked again.
///    Nothing here counts against the line.
/// 2. **Quiz** — the line from its start: the opponent's moves play
///    themselves, each of the user's is asked for. A wrong answer is logged,
///    the right move plays itself, and the line carries on.
/// 3. **Replay** — each move missed in the quiz, asked again on its own.
///
/// The owner calls [Drill.tick] when a timed stage — [Answered], [Missed],
/// [Corrected] — has been on screen long enough, [Drill.next] when the user
/// asks to go on from [Showing], and [Drill.answer] with a move.
library;

import 'package:dartchess/dartchess.dart' show Move;

import '../fen.dart';
import '../pgn/tree_edit.dart' show moveNode;
import 'records.dart' show AttemptPhase;
import 'training_line.dart';

enum Pass { walkthrough, quiz, replay }

/// What the lesson is waiting for.
sealed class Stage {
  const Stage();
}

/// The user's move is asked for.
final class Asking extends Stage {
  const Asking();
}

/// Walkthrough: the user's next move is on the board, to be remembered.
final class Showing extends Stage {
  const Showing();
}

/// A right answer is on the board; the replies come next.
final class Answered extends Stage {
  const Answered();
}

/// A wrong answer is on the board: [san], reaching [fen].
final class Missed extends Stage {
  const Missed(this.san, this.uci, this.fen);

  final String san;
  final String uci;
  final Fen fen;
}

/// The right move has replaced a wrong one on the board.
final class Corrected extends Stage {
  const Corrected();
}

/// The line is done. [clean] is whether the quiz went without a mistake.
final class Finished extends Stage {
  const Finished({required this.clean});

  final bool clean;
}

/// What one answer was, for the attempt log and the move's streak.
typedef DrillAnswer = ({
  int ply,
  Fen fen,
  String played,
  String expected,
  bool correct,
  AttemptPhase phase,
});

final class Drill {
  const Drill._({
    required this.line,
    required this.pass,
    required this.shown,
    required this.stage,
    this.replayMistakes = true,
    this.missed = const [],
    this.replaying = const [],
  });

  /// The line from its start: a walkthrough first when [learn], else the
  /// quiz straight away.
  factory Drill.start(
    TrainingLine line, {
    required bool learn,
    bool replayMistakes = true,
  }) => Drill._(
    line: line,
    replayMistakes: replayMistakes,
    pass: learn ? Pass.walkthrough : Pass.quiz,
    shown: 0,
    stage: const Answered(),
  )._toNextAsk();

  final TrainingLine line;
  final bool replayMistakes;
  final Pass pass;

  /// How many of the line's moves are on the board.
  final int shown;
  final Stage stage;

  /// The plies the quiz got wrong, in order.
  final List<int> missed;

  /// The missed plies the replay has still to ask, the current one first.
  final List<int> replaying;

  /// The ply asked for or shown: the one after the moves on the board, or
  /// the one on top of them while it is being shown or corrected.
  int get ply => switch (stage) {
    Showing() || Corrected() || Answered() => shown - 1,
    _ => shown,
  };

  /// The position on the board.
  Fen get fen => switch (stage) {
    Missed(:final fen) => fen,
    _ => line.fenBefore(shown),
  };

  /// The move that reached [fen], for the board's highlight.
  String? get lastMove => switch (stage) {
    Missed(:final uci) => uci,
    _ => shown == 0 ? null : line.moves[shown - 1].uci,
  };

  /// The move the lesson is about: the one to play, being shown, or being
  /// corrected.
  String get expected => line.moves[ply].san;

  /// Whether a timed stage is on screen: [tick] moves it on.
  bool get timed => stage is Answered || stage is Missed || stage is Corrected;

  /// The user's move, as UCI. Null when nothing is being asked, or the move
  /// is not legal on the board.
  (Drill, DrillAnswer)? answer(String uci) {
    if (stage is! Asking) return null;
    final move = Move.parse(uci);
    final before = fen;
    final node = move == null ? null : moveNode(before, move);
    if (node == null) return null;
    final expected = line.moves[shown];
    final correct = node.fen.position == expected.fen.position;
    final record = (
      ply: shown,
      fen: before,
      played: node.san,
      expected: expected.san,
      correct: correct,
      phase: _phase,
    );
    if (correct)
      return (_with(shown: shown + 1, stage: const Answered()), record);
    final missed = pass == Pass.quiz && !this.missed.contains(shown)
        ? [...this.missed, shown]
        : this.missed;
    return (
      _with(stage: Missed(node.san, node.uci, node.fen), missed: missed),
      record,
    );
  }

  /// Walkthrough: the move being shown is taken back and asked for.
  Drill next() =>
      stage is Showing ? _with(shown: shown - 1, stage: const Asking()) : this;

  /// Moves a timed stage on.
  Drill tick() => switch (stage) {
    Missed() => _with(shown: shown + 1, stage: const Corrected()),
    Corrected() when pass == Pass.walkthrough => _with(
      shown: shown - 1,
      stage: const Asking(),
    ),
    Answered() || Corrected() => _toNextAsk(),
    _ => this,
  };

  /// The line again from the start, in the pass it began with.
  Drill restart({required bool learn}) =>
      Drill.start(line, learn: learn, replayMistakes: replayMistakes);

  AttemptPhase get _phase => switch (pass) {
    Pass.walkthrough => AttemptPhase.learning,
    Pass.quiz => AttemptPhase.drilling,
    Pass.replay => AttemptPhase.replaying,
  };

  /// Plays the opponent's moves up to the user's next one and asks for it
  /// (or, in the walkthrough, shows it); past the end of the line, the next
  /// pass.
  Drill _toNextAsk() {
    if (pass == Pass.replay) return _nextReplay();
    var at = shown;
    while (at < line.moves.length && !line.isYours(at)) {
      at++;
    }
    if (at == line.moves.length) return _passDone();
    if (pass == Pass.quiz) return _with(shown: at, stage: const Asking());
    // The walkthrough lets the opponent's reply be seen before the next move
    // to remember goes on top of it.
    return at > shown
        ? _with(shown: at, stage: const Answered())
        : _with(shown: at + 1, stage: const Showing());
  }

  Drill _passDone() => switch (pass) {
    Pass.walkthrough => _with(pass: Pass.quiz, shown: 0)._toNextAsk(),
    Pass.quiz when replayMistakes && missed.isNotEmpty => _with(
      pass: Pass.replay,
      replaying: [...missed]..sort(),
    )._ask(),
    _ => _finished(),
  };

  /// The whole line on the board, the opponent's last moves included.
  Drill _finished() => _with(
    shown: line.moves.length,
    stage: Finished(clean: missed.isEmpty),
  );

  /// Replay: the next missed ply, once the current one has been answered.
  Drill _nextReplay() {
    final left = replaying.skip(1).toList();
    if (left.isEmpty) return _finished();
    return _with(replaying: left)._ask();
  }

  Drill _ask() => _with(shown: replaying.first, stage: const Asking());

  Drill _with({
    Pass? pass,
    int? shown,
    Stage? stage,
    List<int>? missed,
    List<int>? replaying,
  }) => Drill._(
    line: line,
    replayMistakes: replayMistakes,
    pass: pass ?? this.pass,
    shown: shown ?? this.shown,
    stage: stage ?? this.stage,
    missed: missed ?? this.missed,
    replaying: replaying ?? this.replaying,
  );
}

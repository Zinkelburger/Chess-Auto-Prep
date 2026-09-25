import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../chess/training/drill.dart';
import '../../chess/training/schedule.dart';
import '../../chess/training/sitting.dart';
import '../../chess/training/training_line.dart';
import '../../chess/training/training_options.dart';
import '../../storage/training_store.dart';
import '../../workspace/board_claim.dart';
import 'progress.dart';

/// What a sitting was started for: the lines never trained, the lines due,
/// or one line the user picked.
enum SittingKind { learn, review, line }

/// How long each timed moment of a drill stays on the board.
const correctionDelay = Duration(milliseconds: 1200);
const rewindDelay = Duration(milliseconds: 800);
const replayDelay = Duration(milliseconds: 500);

/// How long a graded line stays on the board, whole, before the next one.
const finishedPause = Duration(milliseconds: 1000);

/// Where a sitting is.
sealed class LessonState {
  const LessonState();
}

/// A line is being drilled; [Lesson.drill] says what it waits for.
final class Drilling extends LessonState {
  const Drilling();
}

/// A reviewed line is done and waits for the user's rating. [clean] is
/// whether it went without a mistake; [graded] is what its mistakes earn,
/// which Space accepts.
final class AwaitingRating extends LessonState {
  const AwaitingRating({required this.clean});

  final bool clean;

  Rating get graded => gradeOf(clean: clean);
}

final class SavingLine extends LessonState {
  const SavingLine();
}

/// The rating could not be written; [retry] tries the same one again.
final class LineNotSaved extends LessonState {
  const LineNotSaved(this.failure, this.rating, {required this.clean});

  final ProgressWrite failure;
  final Rating rating;
  final bool clean;
}

/// Every line of the sitting is done.
final class SittingOver extends LessonState {
  const SittingOver();
}

/// One sitting: the lines it was started with, drilled one after another,
/// each rated and written before the next begins.
///
/// The set is fixed when the sitting starts, so finishing a line cannot pull
/// new ones in behind it. A line rated Again is due now, so it goes to the
/// back of the sitting and comes round once more. Every line is graded from
/// its mistakes — Good when the quiz went clean, Again when not — unless
/// the user rates reviews themselves ([TrainingOptions.rateReviews]); a line
/// never trained is walked through first and always graded for them.
/// [lines] is never empty: the trainer starts no sitting with nothing in it.
class Lesson extends ChangeNotifier {
  Lesson({
    required SittingKind kind,
    required List<TrainingLine> lines,
    required TrainingProgress progress,
    TrainingOptions options = TrainingOptions.defaults,
  }) : this._(kind, lines, progress, options, _isNew(progress, lines.first));

  Lesson._(
    this.kind,
    List<TrainingLine> lines,
    this._progress,
    this.options,
    bool learning,
  ) : _left = lines.sublist(1),
      _learning = learning,
      _drill = Drill.start(
        lines.first,
        learn: learning,
        replayMistakes: options.replayMistakes,
      ) {
    if (learning) _newHere.add(lines.first.key);
    _arm();
  }

  final SittingKind kind;
  final TrainingOptions options;
  final TrainingProgress _progress;
  final List<TrainingLine> _left;
  Drill _drill;

  /// Whether the line on the board began as one never trained, and so is
  /// walked through first and rated for the user.
  bool _learning;

  /// The lines that came into this sitting never trained. Rated Again, one
  /// comes round again as trained, and is still graded for the user.
  final Set<LineKey> _newHere = {};

  /// The lines rated in this sitting, each once however often it came round.
  final Set<LineKey> _rated = {};
  LessonState _state = const Drilling();
  ({int lines, int right, int wrong}) _tally = (lines: 0, right: 0, wrong: 0);

  /// An answer the log did not take, until the next one it does.
  ProgressWrite? _unlogged;
  Timer? _timer;
  bool _disposed = false;
  bool _suspended = false;

  void suspend() {
    _suspended = true;
    _timer?.cancel();
  }

  void resume() {
    if (_disposed || !_suspended) return;
    _suspended = false;
    if (_state is Drilling) _arm();
  }

  TrainingLine get line => _drill.line;
  Drill get drill => _drill;
  LessonState get state => _state;

  /// The lines of the sitting after this one.
  int get left => _left.length;

  /// Lines finished, and the answers given in the quiz and the replays.
  ({int lines, int right, int wrong}) get tally => _tally;

  bool get learning => _learning;

  /// The line's row as it stands, for what each rating would schedule.
  Review get review => _progress.reviewOf(line);

  ProgressWrite? get unlogged => _unlogged;

  /// The board while the sitting holds it: the drill's position, from the
  /// line's side, taking a move only while one is asked for.
  BoardClaim get claim => BoardClaim(
    fen: _drill.fen,
    orientation: line.side,
    lastMove: _drill.lastMove,
    onMove: !_suspended && _state is Drilling && _drill.stage is Asking
        ? play
        : null,
  );

  /// The user's move on the board.
  void play(String uci) {
    if (_disposed || _suspended) return;
    if (_state is! Drilling) return;
    final answered = _drill.answer(uci);
    if (answered == null) return;
    final (drill, answer) = answered;
    // The quiz is what counts: a replayed miss is not a second one.
    if (_drill.pass == Pass.quiz) {
      _tally = answer.correct
          ? (lines: _tally.lines, right: _tally.right + 1, wrong: _tally.wrong)
          : (lines: _tally.lines, right: _tally.right, wrong: _tally.wrong + 1);
    }
    _changed(drill);
    unawaited(_log(line, answer));
  }

  /// Goes on from a move being shown.
  void next() {
    if (_disposed || _suspended) return;
    if (_state is Drilling && _drill.stage is Showing) _changed(_drill.next());
  }

  /// Space: goes on from a move being shown, or takes the grade the line's
  /// mistakes earned when a rating is asked for.
  void proceed() {
    if (_state case AwaitingRating(:final graded)) return rate(graded);
    next();
  }

  /// The user's rating of the line just reviewed.
  void rate(Rating rating) {
    if (_disposed || _suspended) return;
    if (_state case AwaitingRating(:final clean)) {
      unawaited(_save(rating, clean: clean));
    }
  }

  /// The rating that could not be written, again.
  void retry() {
    if (_disposed || _suspended) return;
    if (_state case LineNotSaved(:final rating, :final clean)) {
      unawaited(_save(rating, clean: clean, again: true));
    }
  }

  /// Drops the line from the sitting, unrated and unwritten.
  void skip() {
    if (_disposed || _suspended) return;
    if (_state is SavingLine || _state is SittingOver) return;
    _nextLine();
    notifyListeners();
  }

  /// The line again from its start, walkthrough and all if it is still new.
  void restart() {
    if (_disposed || _suspended) return;
    if (_state is SavingLine || _state is SittingOver) return;
    _state = const Drilling();
    _changed(
      Drill.start(
        line,
        learn: _learning,
        replayMistakes: options.replayMistakes,
      ),
    );
  }

  void _nextLine() {
    _timer?.cancel();
    if (_left.isEmpty) {
      _state = const SittingOver();
      return;
    }
    final line = _left.removeAt(0);
    _learning = _isNew(_progress, line);
    if (_learning) _newHere.add(line.key);
    _state = const Drilling();
    _drill = Drill.start(
      line,
      learn: _learning,
      replayMistakes: options.replayMistakes,
    );
    _arm();
  }

  void _changed(Drill drill) {
    _drill = drill;
    if (drill.stage case Finished(:final clean) when !_graded) {
      _state = AwaitingRating(clean: clean);
    }
    _arm();
    notifyListeners();
  }

  void _arm() {
    _timer?.cancel();
    if (_disposed || _suspended) return;
    final wait = switch (_drill.stage) {
      Finished() => _graded && _state is Drilling ? finishedPause : null,
      Missed() => correctionDelay,
      Corrected() when _drill.pass == Pass.walkthrough => rewindDelay,
      Answered() when _drill.pass == Pass.replay => replayDelay,
      Corrected() || Answered() => Duration(milliseconds: options.replyMillis),
      _ => null,
    };
    if (wait == null) return;
    _timer = Timer(wait, () {
      if (_disposed) return;
      if (_drill.stage case Finished(:final clean)) {
        unawaited(_save(gradeOf(clean: clean), clean: clean));
      } else {
        _changed(_drill.tick());
      }
    });
  }

  Future<void> _log(TrainingLine line, DrillAnswer answer) async {
    final result = await _progress.answered(line, answer);
    if (_disposed) return;
    final unlogged = result is ProgressWritten ? null : result;
    if (unlogged == _unlogged) return;
    _unlogged = unlogged;
    notifyListeners();
  }

  /// Writes the line's rating; [again] writes the rows the last try worked
  /// out, which may be partly on disk already.
  Future<void> _save(
    Rating rating, {
    required bool clean,
    bool again = false,
  }) async {
    final line = this.line;
    _state = const SavingLine();
    notifyListeners();
    final result = again
        ? await _progress.retry()
        : await _progress.finished(line, rating, clean: clean);
    if (_disposed) return;
    if (result is! ProgressWritten) {
      _state = LineNotSaved(result, rating, clean: clean);
      notifyListeners();
      return;
    }
    _rated.add(line.key);
    _tally = (lines: _rated.length, right: _tally.right, wrong: _tally.wrong);
    if (rating == Rating.again &&
        (kind == SittingKind.learn || kind == SittingKind.review))
      _left.add(line);
    _nextLine();
    notifyListeners();
  }

  /// Whether the line on the board is graded from its mistakes rather than
  /// rated by the user.
  bool get _graded => !options.rateReviews || _newHere.contains(line.key);

  static bool _isNew(TrainingProgress progress, TrainingLine line) =>
      progress.status(line) == LineStatus.untrained;

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

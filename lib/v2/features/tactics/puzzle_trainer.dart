import 'dart:async';

import 'package:dartchess/dartchess.dart' show Move;
import 'package:flutter/foundation.dart';

import '../../chess/fen.dart';
import '../../chess/pgn/chapter_edits.dart' show playedAlready;
import '../../chess/pgn/game_tree.dart';
import '../../chess/pgn/tree_edit.dart' show moveNode;
import '../../chess/tactics/puzzle.dart';
import '../../chess/tactics/puzzle_edits.dart';
import '../../chess/tactics/puzzle_run.dart';
import '../../storage/chapter_files.dart';
import '../../storage/settings_store.dart';
import '../../workspace/document_session.dart';
import '../../workspace/engine_analysis.dart';
import 'tactics_set.dart';

/// Puts a game of the set on the board, through the window's door for
/// documents, and answers whether it got there.
typedef OpenPuzzle = Future<bool> Function(ChapterRef set, int game);

/// How long the opponent's reply waits after a right move, so the move just
/// made is seen before the answer to it.
const replyDelay = Duration(milliseconds: 600);

/// How long a solved puzzle stays up before the next one, with auto-advance.
const advanceDelay = Duration(seconds: 3);

/// A sitting of puzzles over the workspace: the run, the puzzle on the
/// board, and what the user does to it.
///
/// A puzzle is a game of the set with the workspace showing only the moves
/// found so far ([DocumentSession.showOnlyTo]). The board's moves come here
/// instead of into the document; a right one moves the cursor along the
/// answer and the opponent's reply follows, a wrong one is said and left
/// off the board. The first attempt at each puzzle is written back into
/// its game's headers, as the old app writes it.
///
/// Whatever game of the set comes onto the board while a run is going —
/// from the list, the next button, the arrow keys — is the puzzle; another
/// document ends the puzzle on the board but not the run. Once the puzzle
/// has been put down ([putDown]: another mode has the board), a game of the
/// set arriving is just a game until the list, Play or next/previous asks
/// for a puzzle again.
final class PuzzleTrainer extends ChangeNotifier {
  PuzzleTrainer({
    required TacticsSet set,
    required DocumentSession session,
    required EngineAnalysis analysis,
    required SettingsStore settings,
    required OpenPuzzle open,
    DateTime Function() now = DateTime.now,
  }) : _set = set,
       _session = session,
       _analysis = analysis,
       _settings = settings,
       _open = open,
       _now = now,
       _showing = (source: session.source, game: session.game) {
    _session.addListener(_documentChanged);
  }

  final TacticsSet _set;
  final DocumentSession _session;
  final EngineAnalysis _analysis;
  final SettingsStore _settings;
  final OpenPuzzle _open;
  final DateTime Function() _now;

  PuzzleRun? _run;
  PuzzleUp? _up;
  Timer? _replyTimer;
  Timer? _advanceTimer;

  /// Set by [putDown] and cleared by the next puzzle asked for, so walking
  /// the set's games in another mode does not put puzzles up behind it.
  bool _parked = false;
  bool _disposed = false;

  /// The document and game the session had on the board when last heard,
  /// so an edit, a flip or an answer hidden is not taken for a game coming.
  ({ChapterRef? source, int? game}) _showing;

  /// The sitting under way, or null.
  PuzzleRun? get run => _run;

  /// The puzzle on the board, or null when none is.
  PuzzleUp? get up => _up;

  /// What the last run came to, until the user closes it; null otherwise.
  Recap? get recap => _run == null ? _finished : null;
  Recap? _finished;

  bool get autoAdvance => _settings.value.autoAdvance;

  /// Keeps [on] in the settings, for this sitting and the next launch. The
  /// pane listens here, not to the settings, so this says it changed.
  void setAutoAdvance(bool on) {
    if (!on) {
      _advanceTimer?.cancel();
      _advanceTimer = null;
    }
    if (on == autoAdvance) return;
    unawaited(_settings.update(_settings.value.copyWith(autoAdvance: on)));
    notifyListeners();
  }

  /// Starts a run over the filtered queue, from [first] when given.
  Future<void> start({Puzzle? first}) async {
    final queue = [for (final puzzle in _set.queue) puzzle.fen];
    if (first != null) {
      queue
        ..remove(first.fen)
        ..insert(0, first.fen);
    }
    if (queue.isEmpty) return;
    await _begin(PuzzleRun(queue: queue));
  }

  /// Puts [puzzle] up now, in the run under way or in a new one from it.
  Future<void> show(Puzzle puzzle) async {
    if (_run == null) return start(first: puzzle);
    await _bringUp(puzzle.fen);
  }

  /// Plays the failed and skipped puzzles of the last run again.
  Future<void> retryMistakes() async {
    final retry = _finished?.retry ?? const [];
    if (retry.isNotEmpty) await _begin(PuzzleRun(queue: retry));
  }

  /// Puts the recap away.
  void closeRecap() {
    _finished = null;
    notifyListeners();
  }

  /// Ends the run and shows what it came to.
  void end() {
    final run = _run;
    if (run == null) return;
    _cancelTimers();
    _finished = run.recap;
    _run = null;
    if (_up != null) {
      _up = null;
      _session.showOnlyTo(null);
    }
    notifyListeners();
  }

  /// Takes the puzzle off the board and keeps the run: another mode has the
  /// board now, and nothing played on it is judged. A puzzle clicked in the
  /// list comes up in the same run.
  void putDown() {
    _parked = true;
    if (_up == null) return;
    _cancelTimers();
    _up = null;
    _session.showOnlyTo(null);
    notifyListeners();
  }

  /// A move made on the board. On a puzzle it is judged; anywhere else it
  /// goes into the document as usual.
  void play(String uci) {
    final up = _up;
    if (up == null || !_set.isOpen) return _session.playMove(uci);
    if (up.waiting) return;
    final reached = playedAlready(
      _session.chapter!,
      at: _session.cursor,
      uci: uci,
    );
    if (up.finished) {
      // Once found or shown, the answer can be walked on the board; nothing
      // else is played into the set.
      if (reached != null) _session.goTo(reached);
      return;
    }
    if (_session.cursor != up.frontier) return;
    if (reached == up.frontier.mainChild) return _found(up);
    _missed(up, uci);
  }

  void _found(PuzzleUp up) {
    final path = up.frontier.mainChild;
    _session.showOnlyTo(path);
    _session.goTo(path);
    final next = up.advanced(path);
    if (next.found >= next.puzzle.answer.length) return _solved(next);
    _up = next.copyWith(
      feedback: Correct(next.userMovesFound, next.puzzle.movesToFind),
      waiting: true,
    );
    notifyListeners();
    _replyTimer = Timer(replyDelay, _reply);
  }

  /// The opponent's move of the answer, then the solver's turn again — or
  /// the end, for an answer that finishes on the opponent's move.
  void _reply() {
    final up = _up;
    if (up == null || _disposed) return;
    final path = up.frontier.mainChild;
    _session.showOnlyTo(path);
    _session.goTo(path);
    final next = up.advanced(path).copyWith(waiting: false);
    if (next.found >= next.puzzle.answer.length) return _solved(next);
    _up = next;
    notifyListeners();
  }

  void _solved(PuzzleUp up) {
    _up = up.copyWith(feedback: const Solved(), waiting: false, finished: true);
    _record(up, Outcome.solved);
    _session.showOnlyTo(null);
    notifyListeners();
    if (autoAdvance) {
      _advanceTimer = Timer(advanceDelay, () {
        _advanceTimer = null;
        if (!_disposed && autoAdvance) unawaited(next());
      });
    }
  }

  void _missed(PuzzleUp up, String uci) {
    final move = Move.parse(uci);
    final san = move == null ? uci : moveNode(_session.fen, move)?.san ?? uci;
    _up = up.copyWith(feedback: Incorrect(san));
    _record(up, Outcome.failed);
    notifyListeners();
  }

  /// Shows the rest of the answer and steps to its next move. Nothing is
  /// written, then or when the puzzle is played again after a reset or a
  /// step back: a revealed puzzle counts as skipped, as the old app counts
  /// it.
  void showSolution() {
    final up = _up;
    if (up == null || up.finished) return;
    _cancelTimers();
    _run = _run?.revealedAt(up.puzzle.fen);
    final rest =
        _session.tree?.lineTo(_session.tree!.endOfLineFrom(up.frontier)) ??
        const [];
    _up = up.copyWith(
      feedback: Revealed([for (final node in rest.skip(up.found)) node.san]),
      waiting: false,
      finished: true,
    );
    _session.showOnlyTo(null);
    _session.goTo(up.frontier.mainChild);
    notifyListeners();
  }

  /// Back to the puzzle's position with the answer hidden again. The
  /// attempt already made still stands.
  void reset() {
    final up = _up;
    if (up == null) return;
    _cancelTimers();
    _up = PuzzleUp.start(up.puzzle, at: _now(), decided: up.decided);
    _session.showOnlyTo(const NodePath.root());
    _session.goTo(const NodePath.root());
    notifyListeners();
  }

  /// The next puzzle of the run, or the recap after the last.
  Future<void> next() async {
    final run = _run;
    if (run == null) return;
    _cancelTimers();
    final following = run.after(_up?.puzzle.fen);
    if (following == null) return end();
    await _bringUp(following);
  }

  /// The puzzle shown before the one on the board in this run, or null.
  Fen? get _before {
    final run = _run;
    final current = _up?.puzzle.fen;
    if (run == null) return null;
    final at = current == null ? run.seen.length : run.seen.indexOf(current);
    return at > 0 ? run.seen[at - 1] : null;
  }

  bool get hasPrevious => _before != null;

  /// Back to the puzzle shown before this one. An attempt already made at
  /// it still stands, so trying it again writes nothing.
  Future<void> previous() async {
    final before = _before;
    if (before == null) return;
    _cancelTimers();
    await _bringUp(before);
  }

  /// Rates the puzzle on the board, 1 to 5; 0 takes the rating away. One
  /// star hides it from the queue from now on; a run never shows a puzzle
  /// twice, so the run under way is not changed.
  void rate(int stars) {
    final up = _up;
    if (up == null) return;
    _cancelTimers();
    final refusal = _session.apply(
      (set) => ratePuzzle(set, index: up.puzzle.index, stars: stars),
    );
    _up = up.copyWith(stars: stars, saveProblem: refusal);
    notifyListeners();
  }

  Future<void> _begin(PuzzleRun run) async {
    _finished = null;
    _run = run;
    notifyListeners();
    await _bringUp(run.queue.first);
  }

  /// Puts the puzzle at [fen] on the board: another game of the set when
  /// the set is open, through the window's door when it is not. The session
  /// says when it got there, and [_documentChanged] takes it from there.
  Future<void> _bringUp(Fen fen) async {
    _parked = false;
    final puzzle = _set.puzzles.where((p) => p.fen == fen).firstOrNull;
    if (puzzle == null) return;
    if (_set.isOpen && _session.game != null) {
      if (_session.game == puzzle.index) return _putUp(puzzle);
      return _session.showGame(puzzle.index);
    }
    await _open(_set.ref, puzzle.index);
  }

  /// The session changed. A game of the set arriving while a run is going
  /// is the puzzle; any other document, or a game of the set that is no
  /// puzzle, takes it away.
  void _documentChanged() {
    final showing = (source: _session.source, game: _session.game);
    if (showing == _showing) return;
    _showing = showing;
    final game = showing.game;
    final puzzle = _set.isOpen && game != null ? _set.at(game) : null;
    if (puzzle != null && _run != null && !_parked) return _putUp(puzzle);
    if (_up == null) return;
    _cancelTimers();
    _up = null;
    notifyListeners();
  }

  void _putUp(Puzzle puzzle) {
    _cancelTimers();
    _up = PuzzleUp.start(
      puzzle,
      at: _now(),
      decided: _run?.outcomes[puzzle.fen],
    );
    _run = _run?.shown(puzzle.fen);
    _session.showOnlyTo(const NodePath.root());
    // The engine would read the answer out; the user turns it back on.
    if (_analysis.enabled) unawaited(_analysis.disable());
    notifyListeners();
  }

  /// Writes the first attempt at [up]'s puzzle into its game, and counts it
  /// in the run. A puzzle already decided, or whose answer was shown first,
  /// has had its attempt: nothing more is written.
  void _record(PuzzleUp up, Outcome outcome) {
    final run = _run;
    if (run == null || !run.counts(up.puzzle.fen)) return;
    final took = _now().difference(up.startedAt).inMilliseconds / 1000;
    _run = run.decided(up.puzzle.fen, outcome, took);
    final refusal = _session.apply(
      (set) => recordAttempt(
        set,
        index: up.puzzle.index,
        solved: outcome == Outcome.solved,
        seconds: took,
        now: _now(),
      ),
    );
    _up = (_up ?? up).copyWith(decided: outcome, saveProblem: refusal);
  }

  void _cancelTimers() {
    _replyTimer?.cancel();
    _replyTimer = null;
    _advanceTimer?.cancel();
    _advanceTimer = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelTimers();
    _session.removeListener(_documentChanged);
    super.dispose();
  }
}

/// What the last thing the user did to the puzzle came to.
sealed class Feedback {
  const Feedback();
}

/// A right move of an answer with more to find: [found] of [of].
final class Correct extends Feedback {
  const Correct(this.found, this.of);

  final int found;
  final int of;
}

/// [san] is not the move.
final class Incorrect extends Feedback {
  const Incorrect(this.san);

  final String san;
}

final class Solved extends Feedback {
  const Solved();
}

/// The answer was shown; [rest] is what was left of it to find.
final class Revealed extends Feedback {
  const Revealed(this.rest);

  final List<String> rest;
}

/// The puzzle on the board and how far the user has got with it.
final class PuzzleUp {
  const PuzzleUp({
    required this.puzzle,
    required this.startedAt,
    this.frontier = const NodePath.root(),
    this.found = 0,
    this.feedback,
    this.waiting = false,
    this.finished = false,
    this.decided,
    this.stars,
    this.saveProblem,
  });

  /// [puzzle] at its position, the clock started [at]. A puzzle put up again
  /// keeps the attempt it had: the first one is the one that counts.
  factory PuzzleUp.start(
    Puzzle puzzle, {
    required DateTime at,
    Outcome? decided,
  }) => PuzzleUp(puzzle: puzzle, startedAt: at, decided: decided);

  final Puzzle puzzle;

  /// When the clock for this attempt started: the puzzle came up or was
  /// reset.
  final DateTime startedAt;

  /// The last move of the answer on the board; the root before the first.
  final NodePath frontier;

  /// How many moves of the answer are on the board, both sides'.
  final int found;

  final Feedback? feedback;

  /// The opponent's reply is on its way; the board takes no move meanwhile.
  final bool waiting;

  /// Solved or shown: the answer is on view and nothing more is judged.
  final bool finished;

  /// How the first attempt went, once there has been one.
  final Outcome? decided;

  /// The rating given since the puzzle came up; null for the file's own.
  final int? stars;

  /// Why the result could not be written into the set, or null.
  final String? saveProblem;

  /// The solver's moves found so far.
  int get userMovesFound => (found + 1) ~/ 2;

  int get rating => stars ?? puzzle.stats.stars;

  /// One more move of the answer on the board, at [path].
  PuzzleUp advanced(NodePath path) =>
      copyWith(frontier: path, found: found + 1);

  PuzzleUp copyWith({
    NodePath? frontier,
    int? found,
    Feedback? feedback,
    bool? waiting,
    bool? finished,
    Outcome? decided,
    int? stars,
    String? saveProblem,
  }) => PuzzleUp(
    puzzle: puzzle,
    startedAt: startedAt,
    frontier: frontier ?? this.frontier,
    found: found ?? this.found,
    feedback: feedback ?? this.feedback,
    waiting: waiting ?? this.waiting,
    finished: finished ?? this.finished,
    decided: decided ?? this.decided,
    stars: stars ?? this.stars,
    saveProblem: saveProblem ?? this.saveProblem,
  );
}

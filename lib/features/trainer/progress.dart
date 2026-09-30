import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../chess/training/drill.dart';
import '../../chess/training/records.dart';
import '../../chess/training/schedule.dart';
import '../../chess/training/sitting.dart';
import '../../chess/training/training_line.dart';
import '../../storage/training_rows.dart' show asWritten;
import '../../storage/training_store.dart';
import '../../storage/document_ref.dart';
import '../../storage/pending_writes.dart';

/// The clock and the dice a trainer runs on, handed in so a test can fix
/// both: the time now, and a number in −1..1 that spreads an interval.
typedef TrainerTime = ({DateTime Function() now, double Function() jitter});

/// What is recorded for the lines of one scope — their schedule, their
/// moves' streaks and the wrong answers given in them — and every change
/// to it.
///
/// Writes go out one after another, each naming what its rows held when
/// they were last read or written here. When another session changed one of
/// them, the write is refused and [stale] says the scope must be read again
/// before anything else is written.
///
/// Each new write names the version of every chapter its lines came from,
/// which the store checks before accepting it. Already accepted answers
/// survive later saves. The workspace's own saves move the version for new
/// answers on ([documentSaved]); training never holds a save up.
class TrainingProgress extends ChangeNotifier {
  TrainingProgress({
    required ProgressFiles files,
    required ProgressLoaded loaded,
    required TrainerTime time,
    this.pendingWrites,
  }) : _files = files,
       _time = time,
       _sources = Map.of(loaded.sources),
       _reviews = {...loaded.reviews},
       _streaks = {...loaded.streaks},
       _saved = {...loaded.streaks},
       _mistakes = [...loaded.mistakes];

  final ProgressFiles _files;
  final PendingWrites? pendingWrites;
  final TrainerTime _time;
  final Map<LineKey, Review> _reviews;

  /// The version of each chapter the rows were read against, by path.
  final Map<String, Revision> _sources;

  /// Each move's streak now, and as the file last had it: answers change the
  /// first at once and reach the file with the line's outcome.
  final Map<StreakKey, MoveStreak> _streaks;
  final Map<StreakKey, MoveStreak> _saved;
  final List<Attempt> _mistakes;
  Future<void> _writes = Future.value();

  /// Line outcomes a write did not finish, oldest first, for [retry]. A
  /// line rated again while its last outcome is unsaved queues the new one
  /// behind it rather than dropping either.
  final _unsaved = <LineKey, List<_Outcome>>{};

  /// Answers a log did not take, oldest first, each with the operation it
  /// was first logged under: the line's next write logs them again, which
  /// the store takes once however often it is asked.
  final _unlogged = <LineKey, List<_Answer>>{};

  /// Exclusions and marks the store answered failed and still holds
  /// ([_waits]), oldest first. The store lands most of them with a later
  /// write, which only asking under the same operation tells
  /// ([_landedCommands]); a write of their lines writes them again first
  /// ([_landUnsaved]).
  final _commands = <ProgressOperation, _Unlanded>{};

  /// The operation each command's obligation was last asked for, while that
  /// command is in play. Only that operation landing clears it.
  final _asked = <Object, ProgressOperation>{};
  bool _stale = false;
  bool _disposed = false;

  Map<LineKey, Review> get reviews => UnmodifiableMapView(_reviews);

  /// Wrong answers in the scope, newest first.
  List<Attempt> get mistakes => _mistakes.reversed.toList();

  /// The workspace saved the chapter at [path] from [before] to [after].
  /// False when [before] is not the version these rows were read against:
  /// the chapter changed some other way, and the scope must be read again.
  bool documentSaved(String path, Revision before, Revision after) {
    final source = _sources[path];
    if (source == null) return true;
    if (source != before || source.nativeIdentity != before.nativeIdentity) {
      return false;
    }
    _sources[path] = after;
    return true;
  }

  /// Whether another session changed the progress under this one, which
  /// must be read again before it writes anything more.
  bool get stale => _stale;

  DateTime get now => _time.now().toUtc();

  LineStatus status(TrainingLine line) =>
      statusOf(line, _reviews[line.key], now);

  /// The line's row, or the row a line never trained starts with.
  Review reviewOf(TrainingLine line) =>
      _reviews[line.key] ?? Review(key: line.key, lineName: line.name);

  /// Logs one answer and counts it towards its move's streak — unless it
  /// was given while the line was being shown, which teaches, not tests.
  Future<ProgressWrite> answered(TrainingLine line, DrillAnswer answer) async {
    final attempt = Attempt(
      key: line.key,
      ply: answer.ply,
      fen: answer.fen,
      played: answer.played,
      expected: answer.expected,
      correct: answer.correct,
      phase: answer.phase,
      at: now,
    );
    if (answer.phase != AttemptPhase.learning) {
      final at = (line: line.key, ply: answer.ply);
      _streaks[at] = streakAfter(
        _streaks[at],
        key: line.key,
        ply: answer.ply,
        correct: answer.correct,
      );
    }
    final logged = (attempt: attempt, operation: _operation());
    final result = await _log(logged);
    if (result is! ProgressWritten) {
      (_unlogged[line.key] ??= []).add(logged);
    } else {
      await _landedCommands();
    }
    return result;
  }

  /// Logs [answer] under its own obligation, so the log that takes it
  /// clears the problem an earlier one reported.
  Future<ProgressWrite> _log(_Answer answer) async {
    final attempt = answer.attempt;
    final logged = _files.logAttempt(attempt, operation: answer.operation);
    final result =
        await pendingWrites?.track(
          attempt,
          logged,
          label: 'Training progress',
          obligation: attempt,
          problem: (result) => result is ProgressWritten
              ? null
              : 'An answer could not be logged.',
        ) ??
        await logged;
    if (result is ProgressWritten && !attempt.correct && !_disposed) {
      _mistakes.add(attempt);
      notifyListeners();
    }
    return result;
  }

  /// Logs again, in order, the answers of [line] the log did not take. One
  /// that fails again stays for the next write; it never holds up the
  /// line's rating, which the store writes after it anyway.
  Future<void> _logUnlogged(LineKey line) async {
    final queue = _unlogged[line];
    if (queue == null) return;
    for (final answer in [...queue]) {
      if (await _log(answer) is ProgressWritten) queue.remove(answer);
    }
    if (queue.isEmpty) _unlogged.remove(line);
  }

  /// Writes a finished line's rating, with the streaks its answers changed
  /// and a history row.
  ///
  /// An earlier outcome of the line that did not land goes first. When it
  /// fails again, this one is worked out on top of it and queued behind it,
  /// so [retry] writes both and the newer rating is never dropped.
  Future<ProgressWrite> finished(
    TrainingLine line,
    Rating rating, {
    required bool clean,
  }) => _serially(() async {
    final earlier = await _landUnsaved(line);
    final outcome = _outcome(line, rating, clean: clean);
    if (earlier is ProgressWritten) return _landed([line], _land(outcome));
    (_unsaved[line.key] ??= []).add(outcome);
    return earlier;
  });

  /// Runs [write] once every outcome of [lines] that did not all land —
  /// the line restarted, skipped or marked after a failed write — has
  /// landed, as [retry] writes it. Its rows may be on disk already, and a
  /// new write's `before` must be what they hold.
  Future<ProgressWrite> _afterUnsaved(
    List<TrainingLine> lines,
    Future<ProgressWrite> Function() write,
  ) async {
    for (final line in lines) {
      final landed = await _landUnsaved(line);
      if (landed is! ProgressWritten) return landed;
    }
    return _landed(lines, write());
  }

  /// [write], then — when it landed — the answers of [lines] and the
  /// commands still waiting asked about again: the store wrote any it held
  /// ahead of [write], and only asking again says so.
  Future<ProgressWrite> _landed(
    List<TrainingLine> lines,
    Future<ProgressWrite> write,
  ) async {
    final result = await write;
    if (result is ProgressWritten) {
      for (final line in lines) {
        await _logUnlogged(line.key);
      }
      await _landedCommands();
    }
    return result;
  }

  /// Writes again, row for row, the answers and outcomes of [line] that did
  /// not all reach the files. The files are replaced one at a time, so some
  /// of their rows may be there already; working an outcome out afresh — a
  /// new time, a new spread — would make those rows look like somebody
  /// else's.
  Future<ProgressWrite> retry(TrainingLine line) =>
      _serially(() => _landUnsaved(line));

  /// Logs the line's unlogged answers, then writes again the commands of
  /// the line that did not land and its unsaved outcomes, in the order they
  /// were worked out, each naming the rows the one before it leaves, and
  /// stops at the first that fails.
  Future<ProgressWrite> _landUnsaved(TrainingLine line) async {
    await _logUnlogged(line.key);
    for (final unlanded in [..._commands.values]) {
      if (!unlanded.reviews.any((change) => change.after.key == line.key)) {
        continue;
      }
      if (_stale) return const ProgressConflict();
      final result = await _heardOf(
        unlanded,
        _files.write(
          reviews: unlanded.reviews,
          history: unlanded.history,
          operation: unlanded.command.operation,
        ),
      );
      // A command refused by one unreadable row wrote nothing and never
      // will; the line's own rows do not wait for it.
      final refused = result is ProgressUnreadable && !result.wholeFile;
      if (result is! ProgressWritten && !refused) return result;
    }
    final queue = _unsaved[line.key];
    while (queue != null && queue.isNotEmpty) {
      final result = await _writeOutcome(queue.first);
      if (result is! ProgressWritten) return result;
      queue.removeAt(0);
    }
    _unsaved.remove(line.key);
    return const ProgressWritten();
  }

  /// The rows a rating of [line] writes, worked out on top of whatever of
  /// the line is still waiting in [_commands] and [_unsaved], which lands
  /// first.
  _Outcome _outcome(TrainingLine line, Rating rating, {required bool clean}) {
    final pending = _unsaved[line.key] ?? const [];
    final before = pending.isEmpty
        ? _commanded(line.key)
        : pending.last.review.after;
    final streaksBefore = {
      for (final MapEntry(:key, :value) in _saved.entries)
        if (key.line == line.key) key: value,
      for (final outcome in pending)
        for (final change in outcome.streaks)
          (line: line.key, ply: change.after.ply): change.after,
    };
    final after = asWritten(
      rated(
        (before ?? reviewOf(line)).copyWith(lineName: line.name),
        rating,
        now: now,
        clean: clean,
        jitter: _time.jitter(),
      ),
    );
    return (
      operation: _operation(),
      review: (before: before, after: after),
      streaks: [
        for (final MapEntry(:key, :value) in _streaks.entries)
          if (key.line == line.key && streaksBefore[key] != value)
            (before: streaksBefore[key], after: value),
      ],
      history: HistoryRow(
        key: line.key,
        at: now,
        rating: rating.name,
        mistake: !clean,
        kind: HistoryKind.trainer,
      ),
    );
  }

  /// Writes [outcome], keeping it for [retry] when it does not land.
  Future<ProgressWrite> _land(_Outcome outcome) async {
    final result = await _writeOutcome(outcome);
    if (result is! ProgressWritten) {
      _unsaved[outcome.review.after.key] = [outcome];
    }
    return result;
  }

  /// A retry writes the same rows under the same operation, so the store
  /// can tell it apart from a new outcome whose rows happen to match.
  Future<ProgressWrite> _writeOutcome(_Outcome outcome) => _write(
    reviews: [outcome.review],
    streaks: outcome.streaks,
    history: [outcome.history],
    operation: outcome.operation,
  );

  /// The line's row once the commands still waiting in [_commands] land.
  Review? _commanded(LineKey line) {
    var review = _reviews[line];
    for (final unlanded in _commands.values) {
      for (final change in unlanded.reviews) {
        if (change.after.key == line) review = change.after;
      }
    }
    return review;
  }

  /// Takes [line] out of every queue, or puts it back.
  Future<ProgressWrite> setExcluded(
    TrainingLine line, {
    required bool excluded,
  }) {
    final command = (
      operation: _operation(),
      key: (line.key, #excluded),
      failed: excluded
          ? 'A line could not be excluded.'
          : 'A line could not be put back.',
    );
    return _serially(
      () => _afterUnsaved(
        [line],
        () => _write(
          reviews: [
            (
              before: _reviews[line.key],
              after: asWritten(reviewOf(line).copyWith(excluded: excluded)),
            ),
          ],
          command: command,
        ),
      ),
      command: command,
    );
  }

  /// Puts the untrained lines of [lines] on the schedule as known, or — when
  /// not [known] — the trained ones back to untrained.
  Future<ProgressWrite> mark(List<TrainingLine> lines, {required bool known}) {
    final operation = _operation();
    final command = (
      operation: operation,
      key: operation,
      failed: 'Lines could not be marked.',
    );
    return _serially(
      () => _afterUnsaved(lines, () {
        final changes = <Change<Review>>[];
        final history = <HistoryRow>[];
        for (final line in lines) {
          final status = this.status(line);
          final trained =
              status == LineStatus.due || status == LineStatus.learned;
          if (known ? status != LineStatus.untrained : !trained) continue;
          final review = reviewOf(line);
          final after = known
              ? markedKnown(review, now: now, nth: changes.length)
              : markedUnknown(review);
          changes.add((before: _reviews[line.key], after: asWritten(after)));
          history.add(
            HistoryRow(
              key: line.key,
              at: now,
              rating: known ? Rating.good.name : '',
              mistake: false,
              kind: HistoryKind.marked,
            ),
          );
        }
        if (changes.isEmpty) return Future.value(const ProgressWritten());
        return _write(reviews: changes, history: history, command: command);
      }),
      command: command,
    );
  }

  /// Writes the rows under [operation], or [command]'s, or a new one. A
  /// [command] the store answers failed and still holds waits in
  /// [_commands].
  Future<ProgressWrite> _write({
    List<Change<Review>> reviews = const [],
    List<Change<MoveStreak>> streaks = const [],
    List<HistoryRow> history = const [],
    ProgressOperation? operation,
    _Command? command,
  }) async {
    if (_stale) return const ProgressConflict();
    final result = await _files.write(
      reviews: reviews,
      streaks: streaks,
      history: history,
      operation: command?.operation ?? operation ?? _operation(),
    );
    if (command != null && _waits(result)) {
      _commands[command.operation] = (
        command: command,
        reviews: reviews,
        history: history,
      );
    }
    _took(result, reviews: reviews, streaks: streaks);
    if (!_disposed) notifyListeners();
    return result;
  }

  /// Asks the store about each command it answered failed. It keeps most
  /// and lands them with any later write; one it did not keep waits for a
  /// write of its lines to write it again.
  Future<void> _landedCommands() async {
    for (final unlanded in [..._commands.values]) {
      await _heardOf(unlanded, _files.commit(unlanded.command.operation));
    }
  }

  /// Takes what the store [answer]s about [unlanded]. A command that landed
  /// is taken as written and clears its obligation, unless a newer command
  /// was asked for under it. One the store settled otherwise leaves
  /// [_commands] with its obligation still failed; a conflict also leaves
  /// the scope stale.
  Future<ProgressWrite> _heardOf(
    _Unlanded unlanded,
    Future<ProgressWrite> answer,
  ) async {
    final result = await answer;
    final command = unlanded.command;
    if (!_commands.containsKey(command.operation) || _waits(result)) {
      return result;
    }
    _commands.remove(command.operation);
    _took(result, reviews: unlanded.reviews);
    if (result is ProgressWritten && _asked[command.key] == command.operation) {
      pendingWrites?.track(
        this,
        Future.value(result),
        label: 'Training progress',
        obligation: command.key,
        problem: (_) => null,
      );
    }
    _answered(command);
    if (!_disposed) notifyListeners();
    return result;
  }

  /// Whether the store still holds a change it answered [result], to land
  /// with a later write: a failure, or a file that holds no rows at all. A
  /// row it could not read settles the change for good.
  static bool _waits(ProgressWrite result) =>
      result is ProgressFailed ||
      result is ProgressUnreadable && result.wholeFile;

  /// Forgets [command]'s operation once the store has settled it.
  void _answered(_Command command) {
    if (_asked[command.key] == command.operation) _asked.remove(command.key);
  }

  /// Takes in what [result] says of rows this owner asked to write.
  void _took(
    ProgressWrite result, {
    List<Change<Review>> reviews = const [],
    List<Change<MoveStreak>> streaks = const [],
  }) {
    switch (result) {
      case ProgressWritten():
        for (final change in reviews) {
          _reviews[change.after.key] = change.after;
        }
        for (final change in streaks) {
          final at = (line: change.after.key, ply: change.after.ply);
          _saved[at] = change.after;
        }
      case ProgressConflict():
        _stale = true;
      case ProgressUnreadable() || ProgressFailed():
        break;
    }
  }

  /// A new operation naming the chapters as they are now.
  ProgressOperation _operation() => ProgressOperation(sources: _sources);

  /// Runs [write] after every write asked for before it, so each one names
  /// the rows the one before it left.
  ///
  /// A failed line outcome waits in [_unsaved] for [retry], so every serial
  /// write reads it again under one obligation and the write that lands it
  /// clears the failure. A [command] — an exclusion or a mark — reports
  /// under its own key, which only that command seen to land clears
  /// ([_heardOf]) or, for an exclusion, a later one of the same line; never
  /// an unrelated write.
  Future<ProgressWrite> _serially(
    Future<ProgressWrite> Function() write, {
    _Command? command,
  }) {
    if (command != null) _asked[command.key] = command.operation;
    final done = _writes.then((_) => write());
    _writes = done.then<void>((_) {
      if (command != null && !_commands.containsKey(command.operation)) {
        _answered(command);
      }
    }, onError: (Object _) {});
    final pending = pendingWrites;
    if (pending == null) return done;
    pending.track(
      this,
      done,
      label: 'Training progress',
      obligation: this,
      problem: (result) =>
          _unsaved.isEmpty && (command != null || result is ProgressWritten)
          ? null
          : 'Some progress could not be saved.',
    );
    if (command == null) return done;
    return pending.track(
      this,
      done,
      label: 'Training progress',
      obligation: command.key,
      problem: (result) => result is ProgressWritten ? null : command.failed,
    );
  }

  /// Writes already accepted by this progress owner survive scope changes.
  Future<void> settle() => _writes;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// One answer, and the operation it is logged under however often.
typedef _Answer = ({Attempt attempt, ProgressOperation operation});

/// An exclusion or a mark: its operation, the obligation it reports under
/// and what that says while the command has not landed.
typedef _Command = ({ProgressOperation operation, Object key, String failed});

/// A command the store answered failed, with the rows it writes.
typedef _Unlanded = ({
  _Command command,
  List<Change<Review>> reviews,
  List<HistoryRow> history,
});

/// Everything one finished line writes.
typedef _Outcome = ({
  ProgressOperation operation,
  Change<Review> review,
  List<Change<MoveStreak>> streaks,
  HistoryRow history,
});

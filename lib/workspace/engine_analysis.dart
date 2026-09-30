import 'dart:async';

import 'package:flutter/foundation.dart';

import '../chess/fen.dart';
import '../chess/threat.dart';
import '../diagnostics/log.dart';
import '../engines/engine.dart';
import '../engines/engine_line.dart';
import '../engines/engine_supervisor.dart';
import 'board_claim.dart';
import 'document_session.dart';

sealed class EngineState {
  const EngineState();
}

final class EngineOff extends EngineState {
  const EngineOff();
}

final class EngineStarting extends EngineState {
  const EngineStarting();
}

final class EngineRunning extends EngineState {
  const EngineRunning(this.name);

  final String name;
}

final class EngineFailed extends EngineState {
  const EngineFailed(this.reason);

  final String reason;
}

/// The engine is up but not following the board: another job has the
/// engines for now, and [reason] says which.
final class EnginePaused extends EngineState {
  const EnginePaused(this.reason);

  final String reason;
}

/// What the engine thinks of one position: the lines it has said something
/// about, in MultiPV order, scores from White's side.
///
/// A line is found by its own [EngineLine.multiPv] number, never by its
/// place in [lines], because a tick can carry 1 and 3 without 2 and the
/// third-best line must not be read as the best one.
final class AnalysisSnapshot {
  const AnalysisSnapshot({required this.fen, required this.lines});

  final Fen fen;
  final List<EngineLine> lines;

  /// The [multiPv]-th best line, or null when this snapshot has none.
  EngineLine? line(int multiPv) =>
      lines.where((line) => line.multiPv == multiPv).firstOrNull;

  EngineLine? get best => line(1);
}

/// What the side not to move would play if it were its turn: the first
/// move of the engine's best line in [fen] with the turn passed, as UCI.
typedef Threat = ({Fen fen, String uci});

/// How deep the look for a threat goes. A fixed depth, so that search ends
/// on its own, a moment before the board's own lines start behind it.
const threatDepth = 12;

/// Keeps the engine on the cursor position and publishes what it finds.
///
/// Owns the engine's lifetime for the workspace: [enable] starts it,
/// [disable] quits it. A snapshot goes out at most every 200 ms with the
/// latest of every line, so a fast engine cannot flood the UI, and at once
/// when a search ends. Knows nothing of the document beyond its position.
///
/// With the threat shown, each position is first searched with the turn
/// passed, to [threatDepth], on the same engine: the engine takes one
/// search at a time, and the board's lines queue behind that short one
/// rather than share the machine with a second process.
final class EngineAnalysis extends ChangeNotifier {
  /// [launch] is asked for an engine each time the analysis is enabled.
  ///
  /// [elsewhere] is a position the board shows in place of the document's
  /// — the explorer Book's free board — which the engine follows while it is
  /// there.
  EngineAnalysis(
    this._session,
    this._launch, {
    int multiPv = 3,
    ValueListenable<BoardClaim?>? elsewhere,
  }) : _multiPv = multiPv,
       _elsewhere = elsewhere {
    _session.anyChange.addListener(_follow);
    _elsewhere?.addListener(_follow);
  }

  final DocumentSession _session;
  final ValueListenable<BoardClaim?>? _elsewhere;
  final Future<EngineStart> Function() _launch;
  int _multiPv;

  /// How many lines each search asks for and the pane shows.
  int get multiPv => _multiPv;

  /// Asks for [lines] from now on: the search under way is started again
  /// with the new count, so the pane never shows rows a search will not
  /// fill.
  void setLines(int lines) {
    if (lines == _multiPv) return;
    _multiPv = lines;
    _stopFollowing();
    _follow();
    _notify();
  }

  /// Quits the engine and starts another, for a change to how it runs —
  /// its threads or its table — that only a fresh process takes.
  Future<void> restart() async {
    if (!enabled) return;
    await disable();
    await enable();
  }

  /// Whether each position is also searched for what the other side
  /// threatens; off until the user's setting says otherwise.
  bool get threatShown => _threatShown;
  bool _threatShown = false;

  /// Shows or stops showing [threat]. Turning it on starts the position
  /// again, threat first; turning it off leaves the lines as they are.
  void showThreat(bool on) {
    if (on == _threatShown) return;
    _threatShown = on;
    if (on) {
      _stopFollowing();
      _follow();
    } else {
      _following?.stopThreat();
      _threat.value = null;
    }
    _notify();
  }

  /// The threat in the position analysed, once its search has ended; null
  /// while it is looked for, when it is not shown and when there is none.
  ValueListenable<Threat?> get threat => _threat;
  final _threat = ValueNotifier<Threat?>(null);

  EngineState _state = const EngineOff();
  Engine? _engine;

  /// The position analysed: the board's, which is the free board's while
  /// [_elsewhere] holds one, and a comment's line while one is shown.
  Fen get position => _elsewhere?.value?.fen ?? _session.boardFen;

  /// Who is keeping the analysis off the board, and why, oldest first. One
  /// entry per holder, so a fill that ends during a training sitting does
  /// not bring back the lines the sitting hides.
  final _pauses = Map<Object, String>.identity();
  _Following? _following;
  AnalysisSnapshot? _snapshot;

  /// Counts the times the engine has been asked for, so a launch that lands
  /// after a [disable] or a second [enable] is dropped instead of adopted.
  int _starts = 0;

  /// Whether an engine that stopped answering has already been replaced
  /// since the analysis was switched on. One that wedges twice is not going
  /// to work, and a pane that restarts for ever never says so.
  bool _replaced = false;
  late final _buffer = _LineBuffer(
    every: const Duration(milliseconds: 200),
    onFlush: _publish,
  );
  bool _disposed = false;

  EngineState get state => switch (pausedFor) {
    final reason? when _state is EngineRunning => EnginePaused(reason),
    _ => _state,
  };

  /// Always for the position the session is on.
  AnalysisSnapshot? get snapshot => _snapshot;

  bool get enabled => _state is EngineStarting || _state is EngineRunning;

  bool get paused => _pauses.isNotEmpty;

  /// Why the engine is paused: the reason of the latest [pause] still held;
  /// null while it is not paused.
  String? get pausedFor => _pauses.values.lastOrNull;

  /// Stops following the board for [holder] and says [reason] in the pane,
  /// keeping the engine warm, until [holder] resumes: a fill has the
  /// machine, and two searches at once would each get half of it.
  void pause(Object holder, String reason) {
    _pauses
      ..remove(holder)
      ..[holder] = reason;
    _stopFollowing();
    _clearSnapshot();
    _notify();
  }

  /// Lets go of [holder]'s pause. The board is followed again, from the
  /// position it is on now, once no other holder is keeping it paused.
  void resume(Object holder) {
    if (_pauses.remove(holder) == null) return;
    _follow();
    _notify();
  }

  Future<void> enable() async {
    if (enabled) return;
    _replaced = false;
    await _start((reason) => reason);
  }

  /// Asks for an engine and takes it up, or reports why there is none.
  /// [failure] turns a launch failure into the sentence the pane shows, so a
  /// restart can say what it was recovering from.
  Future<void> _start(String Function(String reason) failure) async {
    final ticket = ++_starts;
    _set(const EngineStarting());
    final start = await _launch();
    if (_disposed || ticket != _starts) {
      // Turned off, or gone, while the engine was coming up.
      if (start case Started(:final engine)) unawaited(engine.quit());
      return;
    }
    switch (start) {
      case StartFailed(:final reason):
        _set(EngineFailed(failure(reason)));
      case Started(:final engine):
        _engine = engine;
        unawaited(engine.exited.then((exit) => _lost(engine, exit)));
        _set(EngineRunning(engine.name));
        _follow();
    }
  }

  Future<void> disable() async {
    _starts++;
    final engine = _engine;
    _engine = null;
    _stopFollowing();
    _snapshot = null;
    _threat.value = null;
    _set(const EngineOff());
    await engine?.quit();
  }

  /// Analyses the position the board shows. That is the session's cursor
  /// position, and the start position before a chapter is open: the board
  /// is on screen either way, and a switch that says on with blank rows
  /// under it reads as an engine that does not work.
  void _follow() {
    final engine = _engine;
    if (engine == null || paused) {
      // Nothing is searching, so the last score is about a position the
      // cursor has left; the pane and the bar must not keep showing it.
      _clearSnapshot();
      return;
    }
    final fen = position;
    if (fen == _following?.fen) return;
    _stopFollowing();
    if (_threat.value?.fen != fen) _threat.value = null;
    // Asked for first, so the engine runs it to its depth and then starts
    // the lines, which wait for it.
    final threat = _threatShown ? _lookForThreat(engine, fen) : null;
    final search = engine.analyse(fen, multiPv: multiPv);
    _following = _Following(
      fen: fen,
      search: search,
      subscription: search.lines.listen(
        (line) => _buffer.add(line.forWhite(whiteToMove: fen.whiteToMove)),
        onDone: _buffer.flush,
      ),
      threat: threat,
    );
    _snapshot = null;
    _notify();
  }

  /// Searches [fen] with the turn passed and publishes the best move found
  /// when the search ends at its depth. A look that is stopped — the
  /// cursor moved, the threat was turned off — is no longer listened to,
  /// so its shallow answer never lands; nor does one that ends short of
  /// [threatDepth] for any other reason, such as the engine exiting or a
  /// search that failed.
  _Look? _lookForThreat(Engine engine, Fen fen) {
    final passed = threatFen(fen);
    if (passed == null) return null;
    final search = engine.analyse(passed, multiPv: 1, depth: threatDepth);
    EngineLine? best;
    var failed = false;
    return (
      search: search,
      subscription: search.lines.listen(
        (line) {
          if (line.multiPv == 1) best = line;
        },
        onError: (Object error) {
          failed = true;
          log.w('look for the threat in ${passed.value}', error);
        },
        onDone: () {
          if (failed) return;
          if (best case final line? when _reachedThreatDepth(line)) {
            _threat.value = (fen: fen, uci: line.pv.first);
          }
        },
      ),
    );
  }

  void _stopFollowing() {
    final following = _following;
    _following = null;
    _buffer.clear();
    if (following == null) return;
    following.stopThreat();
    unawaited(following.subscription.cancel());
    unawaited(following.search.stop());
  }

  void _publish(List<EngineLine> lines) {
    final fen = _following?.fen;
    if (fen == null) return;
    _snapshot = AnalysisSnapshot(fen: fen, lines: lines);
    _notify();
  }

  void _clearSnapshot() {
    _threat.value = null;
    if (_snapshot == null) return;
    _snapshot = null;
    _notify();
  }

  /// The engine has gone. One that was killed for saying nothing is replaced
  /// once, because the position on the board still wants an evaluation and a
  /// fresh process usually gives one; anything else, and the pane says the
  /// engine stopped.
  void _lost(Engine engine, EngineExit exit) {
    if (_engine != engine) return; // we quit it ourselves
    final name = engine.name;
    _engine = null;
    _stopFollowing();
    _snapshot = null;
    _threat.value = null;
    if (exit == EngineExit.unresponsive && !_replaced) {
      _replaced = true;
      log.w('restart $name', 'it stopped answering and was killed');
      unawaited(
        _start(
          (reason) =>
              '$name did not answer and was restarted; the '
              'engine started in its place did not run: $reason',
        ),
      );
      return;
    }
    final (action, sentence) = exit == EngineExit.unresponsive
        ? ('engine $name stopped answering again', '$name is not answering')
        : ('engine $name exited on its own', '$name stopped unexpectedly');
    log.w(action);
    _set(EngineFailed(sentence));
  }

  void _set(EngineState state) {
    _state = state;
    _notify();
  }

  /// A search or an engine exit can land after the workspace has gone.
  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _session.anyChange.removeListener(_follow);
    _elsewhere?.removeListener(_follow);
    _stopFollowing();
    unawaited(_engine?.quit());
    _engine = null;
    _threat.dispose();
    super.dispose();
  }
}

/// Whether [line] is the threat search's verdict: it reached [threatDepth],
/// or it is a mate, where an engine may stop deepening early.
bool _reachedThreatDepth(EngineLine line) =>
    line.pv.isNotEmpty && (line.depth >= threatDepth || line.score is MateIn);

/// A search for a threat and the one listening to it.
typedef _Look = ({Search search, StreamSubscription<EngineLine> subscription});

final class _Following {
  _Following({
    required this.fen,
    required this.search,
    required this.subscription,
    required this.threat,
  });

  final Fen fen;
  final Search search;
  final StreamSubscription<EngineLine> subscription;
  _Look? threat;

  /// Ends the look for a threat, if one is on; the lines queued behind it
  /// start at once.
  void stopThreat() {
    final look = threat;
    threat = null;
    if (look == null) return;
    unawaited(look.subscription.cancel());
    unawaited(look.search.stop());
  }
}

/// The latest line per MultiPV number, handed out at most once per [every]:
/// the first line after a flush starts the clock, and whatever has arrived
/// when it rings goes out together. A number the engine has not revisited
/// keeps the line it last gave, on purpose, so a deepening line does not
/// blink out of the pane between the ticks that mention it.
final class _LineBuffer {
  _LineBuffer({required this.every, required this.onFlush});

  final Duration every;
  final void Function(List<EngineLine> lines) onFlush;
  final _latest = <int, EngineLine>{};
  Timer? _timer;

  void add(EngineLine line) {
    _latest[line.multiPv] = line;
    _timer ??= Timer(every, flush);
  }

  void flush() {
    _timer?.cancel();
    _timer = null;
    if (_latest.isEmpty) return;
    final lines = _latest.values.toList()
      ..sort((a, b) => a.multiPv.compareTo(b.multiPv));
    onFlush(List.unmodifiable(lines));
  }

  void clear() {
    _timer?.cancel();
    _timer = null;
    _latest.clear();
  }
}

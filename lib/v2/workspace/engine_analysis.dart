import 'dart:async';

import 'package:flutter/foundation.dart';

import '../chess/fen.dart';
import '../diagnostics/log.dart';
import '../engines/engine.dart';
import '../engines/engine_line.dart';
import '../engines/engine_supervisor.dart';
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

/// Keeps the engine on the cursor position and publishes what it finds.
///
/// Owns the engine's lifetime for the workspace: [enable] starts it,
/// [disable] quits it. A snapshot goes out at most every 200 ms with the
/// latest of every line, so a fast engine cannot flood the UI, and at once
/// when a search ends. Knows nothing of the document beyond its position.
final class EngineAnalysis extends ChangeNotifier {
  /// [launch] is asked for an engine each time the analysis is enabled.
  EngineAnalysis(this._session, this._launch, {int multiPv = 3})
    : _multiPv = multiPv {
    _session.addListener(_follow);
  }

  final DocumentSession _session;
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

  EngineState _state = const EngineOff();
  Engine? _engine;
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

  EngineState get state => _state;

  /// Always for the position the session is on.
  AnalysisSnapshot? get snapshot => _snapshot;

  bool get enabled => _state is EngineStarting || _state is EngineRunning;

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
    _set(const EngineOff());
    await engine?.quit();
  }

  /// Analyses the position the board shows. That is the session's cursor
  /// position, and the start position before a chapter is open: the board
  /// is on screen either way, and a switch that says on with blank rows
  /// under it reads as an engine that does not work.
  void _follow() {
    final engine = _engine;
    if (engine == null) {
      // Nothing is searching, so the last score is about a position the
      // cursor has left; the pane and the bar must not keep showing it.
      _clearSnapshot();
      return;
    }
    final fen = _session.fen;
    if (fen == _following?.fen) return;
    _stopFollowing();
    final search = engine.analyse(fen, multiPv: multiPv);
    _following = _Following(
      fen: fen,
      search: search,
      subscription: search.lines.listen(
        (line) => _buffer.add(line.forWhite(whiteToMove: fen.whiteToMove)),
        onDone: _buffer.flush,
      ),
    );
    _snapshot = null;
    _notify();
  }

  void _stopFollowing() {
    final following = _following;
    _following = null;
    _buffer.clear();
    if (following == null) return;
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
    _session.removeListener(_follow);
    _stopFollowing();
    unawaited(_engine?.quit());
    _engine = null;
    super.dispose();
  }
}

final class _Following {
  const _Following({
    required this.fen,
    required this.search,
    required this.subscription,
  });

  final Fen fen;
  final Search search;
  final StreamSubscription<EngineLine> subscription;
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

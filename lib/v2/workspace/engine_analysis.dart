import 'dart:async';

import 'package:flutter/foundation.dart';

import '../chess/fen.dart';
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

/// What the engine thinks of one position: one entry per MultiPV slot in
/// order, scores from White's side.
final class AnalysisSnapshot {
  const AnalysisSnapshot({required this.fen, required this.lines});

  final Fen fen;
  final List<EngineLine> lines;

  EngineLine get best => lines.first;
}

/// Keeps the engine on the cursor position and publishes what it finds.
///
/// Owns the engine's lifetime for the workspace: [enable] starts it,
/// [disable] quits it. A snapshot goes out at most every 200 ms with the
/// latest of every line, so a fast engine cannot flood the UI, and at once
/// when a search ends. Knows nothing of the document beyond its position.
final class EngineAnalysis extends ChangeNotifier {
  /// [launch] is asked for an engine each time the analysis is enabled.
  EngineAnalysis(this._session, this._launch, {this.multiPv = 3}) {
    _session.addListener(_follow);
  }

  final DocumentSession _session;
  final Future<EngineStart> Function() _launch;
  final int multiPv;
  EngineState _state = const EngineOff();
  Engine? _engine;
  _Following? _following;
  AnalysisSnapshot? _snapshot;
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
    _set(const EngineStarting());
    final start = await _launch();
    if (_disposed || _state is! EngineStarting) {
      // Turned off, or gone, while the engine was coming up.
      if (start case Started(:final engine)) unawaited(engine.quit());
      return;
    }
    switch (start) {
      case StartFailed(:final reason):
        _set(EngineFailed(reason));
      case Started(:final engine):
        _engine = engine;
        unawaited(engine.exited.then((_) => _lost(engine)));
        _set(EngineRunning(engine.name));
        _follow();
    }
  }

  Future<void> disable() async {
    final engine = _engine;
    _engine = null;
    _stopFollowing();
    _snapshot = null;
    _set(const EngineOff());
    await engine?.quit();
  }

  /// Analyses the session's position while a document is open; with none,
  /// the engine idles rather than search a board nobody is looking at.
  void _follow() {
    final engine = _engine;
    if (engine == null) return;
    if (_session.chapter == null) {
      _stopFollowing();
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
    notifyListeners();
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
    notifyListeners();
  }

  void _lost(Engine engine) {
    if (_engine != engine) return; // we quit it ourselves
    _engine = null;
    _stopFollowing();
    _set(EngineFailed('${engine.name} stopped unexpectedly'));
  }

  void _set(EngineState state) {
    _state = state;
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

/// The latest line per MultiPV slot, handed out at most once per [every]:
/// the first line after a flush starts the clock, and whatever has arrived
/// when it rings goes out together.
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

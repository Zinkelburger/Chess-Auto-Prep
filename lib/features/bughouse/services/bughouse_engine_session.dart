import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/bughouse_engine_settings.dart';
import '../models/bughouse_state.dart';
import 'bughouse_bundle.dart';
import 'bughouse_engine.dart';

/// The one live engine behind the lab, and the rules for holding it.
///
/// Loading Hivemind costs a second or two and a 54 MB network, so the process
/// is started lazily, at most once at a time, and let go of when nobody is
/// looking. Three rules, each learned the hard way:
///
///   * Two callers asking at once (the analysis pump plus a "compare clocks"
///     press during the first load) share one launch, rather than starting two
///     processes and orphaning whichever lost the assignment.
///   * A process that has exited is not an engine. Without the liveness check
///     the lab kept handing back a corpse and every pass waited out its full
///     timeout.
///   * An injected engine — a test fake, or a local build — outlives the pane
///     by definition, so it is released but never disposed.
///
/// The session also owns the `info` subscription, so folding live lines in
/// follows the engine rather than the caller that happened to launch it, and
/// it remembers whether the process still has to be told about the user's
/// settings: a freshly launched process is back at the engine's own defaults
/// and is configured by exactly the same path as a settings change.
class BughouseEngineSession {
  BughouseEngineSession({
    this.engineOverride,
    required this.onInfo,
    required this.onChanged,
    this.launch = launchBundled,
  });

  /// Injected engine, for tests and for pointing at a local engine build.
  final BughouseAnalysisEngine? engineOverride;

  /// Where live `info` lines go while a search runs.
  final void Function(BughouseInfo info) onInfo;

  /// Called whenever [engine] or [isStarting] changes.
  final VoidCallback onChanged;

  /// Starts a process. The default installs the bundle and launches Hivemind.
  final Future<BughouseAnalysisEngine> Function() launch;

  BughouseAnalysisEngine? _engine;

  /// The engine in hand, or null while there is none.
  BughouseAnalysisEngine? get engine => _engine;

  bool get isReady => _engine != null;

  /// The launch in flight, if any.
  Future<BughouseAnalysisEngine>? _launching;

  bool _starting = false;

  /// True from the moment a launch is asked for until it has answered.
  bool get isStarting => _starting;

  StreamSubscription<BughouseInfo>? _infoSub;

  /// Whether the live process still has to be told about the settings.
  ///
  /// Applied on the engine's own command queue immediately before a search
  /// rather than the moment the user turns a dial: a `setoption` sent while a
  /// pass is in flight would sit behind it anyway.
  bool _optionsDirty = true;

  /// The process is no longer running on the settings last applied — because
  /// they changed, or because something else (a match) reconfigured it.
  void markOptionsDirty() => _optionsDirty = true;

  /// Which inference backend the engine reported at load, or empty.
  String get backendLabel => _engine?.backend ?? '';

  /// What the running engine reported about workers, threads and batch — the
  /// honest answer to "how many cores is it using", since Hivemind fixes its
  /// worker count and has no `Threads` option to offer.
  String get backendDetail => _engine?.backendDetail ?? '';

  /// Installs the bundle if it has to and starts Hivemind from it.
  static Future<BughouseAnalysisEngine> launchBundled() async {
    final executable = await BughouseBundle.ensureInstalled();
    return BughouseEngine.launch(
      executablePath: executable,
      modelPath: BughouseBundle.modelPath!,
      libraryPath: BughouseBundle.libraryPath,
    );
  }

  /// The live engine, launching one when there is none.
  Future<BughouseAnalysisEngine> acquire() {
    final existing = _engine ?? engineOverride;
    if (existing != null && existing.isAlive) {
      if (!identical(_engine, existing)) _adopt(existing);
      return Future.value(existing);
    }
    if (existing != null && !existing.isAlive) {
      release();
    }
    return _launching ??= _startProcess();
  }

  Future<BughouseAnalysisEngine> _startProcess() async {
    _starting = true;
    onChanged();
    try {
      final engine = await launch();
      _adopt(engine);
      return engine;
    } finally {
      _launching = null;
      _starting = false;
      onChanged();
    }
  }

  /// Takes ownership of [engine] and starts folding its `info` lines in.
  void _adopt(BughouseAnalysisEngine engine) {
    unawaited(_infoSub?.cancel() ?? Future.value());
    _infoSub = engine.infoStream.listen(onInfo);
    _engine = engine;
    // A process we have not configured yet is on the engine's own defaults.
    _optionsDirty = true;
  }

  /// Pushes [settings] into [engine], once per change.
  ///
  /// `Hash` and `BatchSize` are the two that reconfigure the engine itself;
  /// `MultiPV` rides along on every [BughouseAnalysisEngine.configure] and the
  /// think time never reaches the process. Takes the engine explicitly
  /// because the caller holds the one it acquired, which may already have
  /// been released here by the time its search is about to start.
  Future<void> applyOptions(
    BughouseAnalysisEngine engine,
    BughouseEngineSettings settings,
  ) async {
    if (!_optionsDirty) return;
    // Cleared first: a failure must not retry on every pass forever, and the
    // error is surfaced by the caller either way.
    _optionsDirty = false;
    try {
      await engine.setOption('Hash', settings.hashMb);
      await engine.setOption('BatchSize', settings.batchSize);
      if (engine is BughouseEngine) {
        await engine.setCpuLimit(settings.cores);
      }
    } catch (_) {
      _optionsDirty = true;
      rethrow;
    }
  }

  /// Interrupts whatever the engine is searching; `bestmove` still follows.
  void stop() => _engine?.stop();

  /// Lets go of the engine so the next [acquire] starts afresh, without
  /// stopping the process.
  void release() {
    unawaited(_infoSub?.cancel() ?? Future.value());
    _infoSub = null;
    _engine = null;
  }

  /// Lets go of the engine, and stops the process unless it is one a caller
  /// handed us — an injected engine outlives the pane by definition.
  Future<void> shutDown() async {
    final engine = _engine;
    if (engine == null) return;
    release();
    if (identical(engine, engineOverride)) return;
    await engine.dispose();
    onChanged();
  }

  /// Stops the process this session launched, if any. Synchronous, for a
  /// caller's own `dispose`; the process exit is not waited for.
  void dispose() {
    unawaited(_infoSub?.cancel() ?? Future.value());
    _infoSub = null;
    final engine = _engine;
    if (engine != null && !identical(engine, engineOverride)) {
      unawaited(engine.dispose());
    }
    _engine = null;
  }
}

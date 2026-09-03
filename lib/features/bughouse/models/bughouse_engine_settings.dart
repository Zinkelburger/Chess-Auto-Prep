import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../utils/log.dart';

/// The engine knobs Hivemind actually has, and how hard it is asked to think.
///
/// Asked of the binary rather than assumed. `uci` advertises `Hash`,
/// `BatchSize`, `MultiPV`, `Ponder` and a row of MCTS tuning permilles
/// alongside the three bughouse rule options — and, importantly, it does
/// **not** advertise `Threads`. The worker count is fixed by the build (it
/// reports `workers 4 intra-op threads 5` here and silently ignores
/// `setoption name Threads`), so there is no core count to offer. The panel
/// reports what the engine chose instead of showing a slider that does
/// nothing; `BatchSize` is the knob that genuinely changes how much work goes
/// to the CPU at once, and it is the one offered in its place.
@immutable
class BughouseEngineSettings {
  const BughouseEngineSettings({
    this.hashMb = 256,
    this.batchSize = 8,
    this.lines = 3,
    this.thinkSeconds = 30,
  });

  /// The `Hash` option, in MB — the search tree's memory.
  ///
  /// The engine's own default is 16 MB, which is small for an MCTS tree that
  /// gets thirty seconds a pass; 256 is the desktop default here. Raising it
  /// costs nothing but memory and is what "give the engine more room" means.
  final int hashMb;

  /// The `BatchSize` option: how many positions go to the network at once.
  ///
  /// Left at the engine's own default. Larger batches keep more of the CPU
  /// busy per evaluation and raise nodes per second; they also make the search
  /// coarser, because a batch is expanded before any of it is scored.
  final int batchSize;

  /// `MultiPV` — how many ranked lines each pass reports.
  final int lines;

  /// The ceiling on one thinking pass, in seconds.
  ///
  /// Hivemind has no `go infinite`, so "keeps thinking" is built from passes
  /// that each think longer than the last (see the controller's pump). This is
  /// where that doubling stops, and it is the honest form of "how hard should
  /// the engine work" for an engine with no depth limit to set.
  final int thinkSeconds;

  static const List<int> hashChoices = [16, 64, 256, 512, 1024, 2048, 4096];
  static const List<int> batchChoices = [1, 4, 8, 16, 32, 64, 128, 256];
  static const List<int> lineChoices = [1, 2, 3, 4, 5];
  static const List<int> thinkChoices = [5, 10, 30, 60, 120];

  BughouseEngineSettings copyWith({
    int? hashMb,
    int? batchSize,
    int? lines,
    int? thinkSeconds,
  }) => BughouseEngineSettings(
    hashMb: hashMb ?? this.hashMb,
    batchSize: batchSize ?? this.batchSize,
    lines: lines ?? this.lines,
    thinkSeconds: thinkSeconds ?? this.thinkSeconds,
  );

  /// Whether moving from [other] to this needs the process reconfigured, as
  /// opposed to only changing what the next search is asked for.
  bool reconfigures(BughouseEngineSettings other) =>
      hashMb != other.hashMb || batchSize != other.batchSize;

  @override
  bool operator ==(Object other) =>
      other is BughouseEngineSettings &&
      other.hashMb == hashMb &&
      other.batchSize == batchSize &&
      other.lines == lines &&
      other.thinkSeconds == thinkSeconds;

  @override
  int get hashCode => Object.hash(hashMb, batchSize, lines, thinkSeconds);

  // ----------------------------------------------------------- persistence

  static const String _hashKey = 'bughouse.engine.hash_mb';
  static const String _batchKey = 'bughouse.engine.batch_size';
  static const String _linesKey = 'bughouse.engine.lines';
  static const String _thinkKey = 'bughouse.engine.think_seconds';

  /// Reads the saved settings. A broken preference store costs the user their
  /// knobs, not the pane, so any failure falls back to the defaults.
  static Future<BughouseEngineSettings> load() async {
    const fallback = BughouseEngineSettings();
    try {
      final prefs = await SharedPreferences.getInstance();
      return BughouseEngineSettings(
        hashMb: _pick(prefs.getInt(_hashKey), hashChoices, fallback.hashMb),
        batchSize: _pick(
          prefs.getInt(_batchKey),
          batchChoices,
          fallback.batchSize,
        ),
        lines: _pick(prefs.getInt(_linesKey), lineChoices, fallback.lines),
        thinkSeconds: _pick(
          prefs.getInt(_thinkKey),
          thinkChoices,
          fallback.thinkSeconds,
        ),
      );
    } catch (e) {
      log.w('Could not read the bughouse engine settings: $e');
      return fallback;
    }
  }

  Future<void> save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_hashKey, hashMb);
      await prefs.setInt(_batchKey, batchSize);
      await prefs.setInt(_linesKey, lines);
      await prefs.setInt(_thinkKey, thinkSeconds);
    } catch (e) {
      log.w('Could not save the bughouse engine settings: $e');
    }
  }

  /// A stored value only counts when it is still one of the offered choices —
  /// otherwise a value written by an older build leaves a dropdown with no
  /// matching item, which throws rather than degrading.
  static int _pick(int? stored, List<int> choices, int fallback) =>
      stored != null && choices.contains(stored) ? stored : fallback;
}

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../utils/log.dart';

/// The engine knobs Hivemind actually has, and how hard it is asked to think.
///
/// Asked of the binary rather than assumed. `uci` advertises `Hash`,
/// `BatchSize`, `MultiPV`, `Ponder` and a row of MCTS tuning permilles
/// alongside the three bughouse rule options — and, importantly, it does
/// **not** advertise `Threads`. The worker count is a compile-time constant
/// of the build (four search workers) and the engine hands every remaining
/// core to ONNX Runtime as intra-op threads, so it already uses the whole
/// machine and there is no core count to offer. The panel reports what the
/// engine chose instead of showing a control that does nothing.
///
/// Each value is a free integer inside a range rather than one of a fixed
/// list of choices: the ranges are the engine's own (`Hash` 1–33554432 MB,
/// `BatchSize` 1–1024, `MultiPV` 1–500), narrowed to what a desktop can use.
@immutable
class BughouseEngineSettings {
  const BughouseEngineSettings({
    this.hashMb = 256,
    this.batchSize = 8,
    this.lines = 3,
    this.thinkSeconds = 30,
  });

  /// Reads whatever was stored, clamping each value into its range, so a
  /// value written by hand or by an older build can never leave the panel
  /// with a number it will not accept.
  factory BughouseEngineSettings.clamped({
    int? hashMb,
    int? batchSize,
    int? lines,
    int? thinkSeconds,
  }) {
    const fallback = BughouseEngineSettings();
    return BughouseEngineSettings(
      hashMb: (hashMb ?? fallback.hashMb).clamp(hashMin, hashMax),
      batchSize: (batchSize ?? fallback.batchSize).clamp(batchMin, batchMax),
      lines: (lines ?? fallback.lines).clamp(linesMin, linesMax),
      thinkSeconds: (thinkSeconds ?? fallback.thinkSeconds).clamp(
        thinkMin,
        thinkMax,
      ),
    );
  }

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
  /// the engine work" for an engine with no depth limit to set. The passes
  /// themselves never stop.
  final int thinkSeconds;

  static const int hashMin = 16;
  static const int hashMax = 65536;
  static const int batchMin = 1;
  static const int batchMax = 1024;
  static const int linesMin = 1;
  static const int linesMax = 10;
  static const int thinkMin = 1;
  static const int thinkMax = 3600;

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
    try {
      final prefs = await SharedPreferences.getInstance();
      return BughouseEngineSettings.clamped(
        hashMb: prefs.getInt(_hashKey),
        batchSize: prefs.getInt(_batchKey),
        lines: prefs.getInt(_linesKey),
        thinkSeconds: prefs.getInt(_thinkKey),
      );
    } catch (e) {
      log.w('Could not read the bughouse engine settings: $e');
      return const BughouseEngineSettings();
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
}

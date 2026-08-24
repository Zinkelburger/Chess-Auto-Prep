/// Time controls for engine-vs-engine play.
///
/// The four shapes cover what every tournament manager offers (Scid vs PC's
/// "Time per Game" / "Time per Move", cutechess-cli's `-each tc=` /
/// `depth=` / `nodes=`):
///
/// * [TimeControlKind.movetime]    — a fixed think time per move.
/// * [TimeControlKind.incremental] — a clock: base + increment, optionally
///   with a moves-per-session period (`40/60+0.6`).
/// * [TimeControlKind.fixedDepth]  — search to a depth, no clock.
/// * [TimeControlKind.fixedNodes]  — search a node budget, no clock.
///
/// Only the clock modes can lose on time; the other two are untimed by
/// construction and a slow engine merely makes the match take longer.
library;

enum TimeControlKind { movetime, incremental, fixedDepth, fixedNodes }

class TimeControl {
  const TimeControl({
    required this.kind,
    this.movetimeMs = 2000,
    this.baseMs = 60000,
    this.incrementMs = 600,
    this.movesPerSession,
    this.depth = 12,
    this.nodes = 1000000,
  });

  /// A fixed think time per move — the default, and the one people mean when
  /// they say "two seconds a move".
  const TimeControl.perMove(int milliseconds)
    : this(kind: TimeControlKind.movetime, movetimeMs: milliseconds);

  /// A real clock. [movesPerSession] null means sudden death (`60+0.6`);
  /// otherwise the clock refills every N moves (`40/60+0.6`).
  const TimeControl.clock({
    required int baseMs,
    int incrementMs = 0,
    int? movesPerSession,
  }) : this(
         kind: TimeControlKind.incremental,
         baseMs: baseMs,
         incrementMs: incrementMs,
         movesPerSession: movesPerSession,
       );

  const TimeControl.fixedDepth(int depth)
    : this(kind: TimeControlKind.fixedDepth, depth: depth);

  const TimeControl.fixedNodes(int nodes)
    : this(kind: TimeControlKind.fixedNodes, nodes: nodes);

  final TimeControlKind kind;

  /// [TimeControlKind.movetime]: think time per move.
  final int movetimeMs;

  /// [TimeControlKind.incremental]: starting clock and per-move increment.
  final int baseMs;
  final int incrementMs;

  /// Moves before the clock refills with [baseMs] again; null = sudden death.
  final int? movesPerSession;

  final int depth;
  final int nodes;

  bool get isTimed => kind == TimeControlKind.incremental;

  /// Hard wall-clock ceiling for one search, past which the engine is
  /// treated as hung rather than merely slow.
  ///
  /// Scid vs. PC forfeits a per-move engine at 175% of its nominal period;
  /// the same allowance is used here, with a floor so a 100 ms control does
  /// not fail on process scheduling jitter.
  Duration hardLimitFor({int? remainingMs}) {
    switch (kind) {
      case TimeControlKind.movetime:
        final ms = (movetimeMs * 1.75).round() + 2000;
        return Duration(milliseconds: ms.clamp(3000, 600000));
      case TimeControlKind.incremental:
        final left = remainingMs ?? baseMs;
        return Duration(
          milliseconds: (left + incrementMs + 5000).clamp(5000, 3600000),
        );
      case TimeControlKind.fixedDepth:
      case TimeControlKind.fixedNodes:
        return const Duration(minutes: 10);
    }
  }

  /// Short human label — `2.0s/move`, `60s+0.6s`, `40/60s+0.6s`, `depth 12`.
  String get label {
    switch (kind) {
      case TimeControlKind.movetime:
        return '${_secs(movetimeMs)}s/move';
      case TimeControlKind.incremental:
        final period = movesPerSession == null ? '' : '$movesPerSession/';
        final inc = incrementMs == 0 ? '' : '+${_secs(incrementMs)}s';
        return '$period${_secs(baseMs)}s$inc';
      case TimeControlKind.fixedDepth:
        return 'depth $depth';
      case TimeControlKind.fixedNodes:
        return '$nodes nodes';
    }
  }

  /// Value for the PGN `TimeControl` tag (PGN standard §9.6). Untimed
  /// searches have no standard spelling, so they report as unknown.
  String get pgnTag {
    switch (kind) {
      case TimeControlKind.movetime:
        return '*${_secs(movetimeMs)}';
      case TimeControlKind.incremental:
        final period = movesPerSession == null ? '' : '$movesPerSession/';
        final inc = incrementMs == 0 ? '' : '+${_secs(incrementMs)}';
        return '$period${_secs(baseMs)}$inc';
      case TimeControlKind.fixedDepth:
      case TimeControlKind.fixedNodes:
        return '?';
    }
  }

  static String _secs(int ms) {
    final v = ms / 1000;
    if (v == v.roundToDouble()) return v.toStringAsFixed(0);
    return v.toStringAsFixed(v * 10 == (v * 10).roundToDouble() ? 1 : 2);
  }

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'movetimeMs': movetimeMs,
    'baseMs': baseMs,
    'incrementMs': incrementMs,
    if (movesPerSession != null) 'movesPerSession': movesPerSession,
    'depth': depth,
    'nodes': nodes,
  };

  factory TimeControl.fromJson(Map<String, dynamic> json) => TimeControl(
    kind: TimeControlKind.values.firstWhere(
      (k) => k.name == json['kind'],
      orElse: () => TimeControlKind.movetime,
    ),
    movetimeMs: (json['movetimeMs'] as num?)?.toInt() ?? 2000,
    baseMs: (json['baseMs'] as num?)?.toInt() ?? 60000,
    incrementMs: (json['incrementMs'] as num?)?.toInt() ?? 600,
    movesPerSession: (json['movesPerSession'] as num?)?.toInt(),
    depth: (json['depth'] as num?)?.toInt() ?? 12,
    nodes: (json['nodes'] as num?)?.toInt() ?? 1000000,
  );

  TimeControl copyWith({
    TimeControlKind? kind,
    int? movetimeMs,
    int? baseMs,
    int? incrementMs,
    Object? movesPerSession = _unset,
    int? depth,
    int? nodes,
  }) => TimeControl(
    kind: kind ?? this.kind,
    movetimeMs: movetimeMs ?? this.movetimeMs,
    baseMs: baseMs ?? this.baseMs,
    incrementMs: incrementMs ?? this.incrementMs,
    movesPerSession: movesPerSession == _unset
        ? this.movesPerSession
        : movesPerSession as int?,
    depth: depth ?? this.depth,
    nodes: nodes ?? this.nodes,
  );

  static const Object _unset = Object();

  @override
  String toString() => 'TimeControl($label)';
}

/// Presets offered in the new-tournament dialog, in the order they appear.
const List<({String label, TimeControl tc})> kTimeControlPresets = [
  (label: '1 s / move', tc: TimeControl.perMove(1000)),
  (label: '2 s / move (default)', tc: TimeControl.perMove(2000)),
  (label: '5 s / move', tc: TimeControl.perMove(5000)),
  (
    label: 'Bullet — 10 s + 0.1 s',
    tc: TimeControl.clock(baseMs: 10000, incrementMs: 100),
  ),
  (
    label: 'Blitz — 60 s + 0.6 s',
    tc: TimeControl.clock(baseMs: 60000, incrementMs: 600),
  ),
  (
    label: 'Rapid — 300 s + 3 s',
    tc: TimeControl.clock(baseMs: 300000, incrementMs: 3000),
  ),
  (
    label: 'Classical — 40/600 s + 10 s',
    tc: TimeControl.clock(
      baseMs: 600000,
      incrementMs: 10000,
      movesPerSession: 40,
    ),
  ),
  (label: 'Fixed depth 12', tc: TimeControl.fixedDepth(12)),
  (label: 'Fixed 1M nodes', tc: TimeControl.fixedNodes(1000000)),
];

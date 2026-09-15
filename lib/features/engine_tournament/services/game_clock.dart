/// The two clocks of one game, and the `go` limits they translate into.
library;

import 'package:dartchess/dartchess.dart' show Side;

import '../models/time_control.dart';
import 'uci_protocol.dart';

/// Slack allowed on a clock before the flag falls, covering pipe latency and
/// process scheduling rather than the engine's own thinking. cutechess calls
/// the same knob `-timemargin`; a desktop running several games at once
/// needs more of it than a dedicated test box.
const int kTimeMarginMs = 500;

/// Scid vs. PC forfeits a per-move engine at 175% of its nominal period.
const double _perMoveOvershootFactor = 1.75;

/// Runs both clocks for one game under [timeControl].
///
/// Untimed controls (fixed depth or nodes) carry a clock that never moves
/// and never forfeits; a slow engine there is caught by the hang guard in
/// `UciEngine.search` instead. A per-move control has no clock either, but
/// does forfeit a move that overshoots its budget by more than 175%.
class GameClock {
  GameClock(this.timeControl)
    : _remainingMs = {
        Side.white: timeControl.baseMs,
        Side.black: timeControl.baseMs,
      };

  final TimeControl timeControl;
  final Map<Side, int> _remainingMs;
  final Map<Side, int> _movesThisSession = {Side.white: 0, Side.black: 0};

  /// Milliseconds left on [side]'s clock. Meaningful only when
  /// [TimeControl.isTimed]; the other kinds report the untouched base.
  int remainingMs(Side side) => _remainingMs[side]!;

  /// What to show for [side], or null when the control has no clock.
  int? displayMs(Side side) => timeControl.isTimed ? remainingMs(side) : null;

  /// Hang guard for [side]'s next search.
  Duration hardLimitFor(Side side) =>
      timeControl.hardLimitFor(remainingMs: remainingMs(side));

  /// The `go` limits for [side]'s next move.
  GoLimits limitsFor(Side side) {
    final tc = timeControl;
    switch (tc.kind) {
      case TimeControlKind.movetime:
        return GoLimits(movetimeMs: tc.movetimeMs);
      case TimeControlKind.fixedDepth:
        return GoLimits(depth: tc.depth);
      case TimeControlKind.fixedNodes:
        return GoLimits(nodes: tc.nodes);
      case TimeControlKind.incremental:
        final period = tc.movesPerSession;
        return GoLimits(
          // A flag that has not yet fallen is still a clock: never send 0.
          whiteTimeMs: _atLeastOne(remainingMs(Side.white)),
          blackTimeMs: _atLeastOne(remainingMs(Side.black)),
          whiteIncrementMs: tc.incrementMs,
          blackIncrementMs: tc.incrementMs,
          movesToGo: period == null
              ? null
              : period - (_movesThisSession[side]! % period),
        );
    }
  }

  /// Charge [elapsedMs] to [side] for the move just made.
  ///
  /// Returns true when the flag fell, in which case the clock is left as it
  /// was so the forfeit can be reported against it. Otherwise the increment
  /// is added and, at the end of a session, the base time is refilled.
  bool charge(Side side, int elapsedMs) {
    final tc = timeControl;
    switch (tc.kind) {
      case TimeControlKind.movetime:
        final ceiling =
            (tc.movetimeMs * _perMoveOvershootFactor).round() + kTimeMarginMs;
        return elapsedMs > ceiling;
      case TimeControlKind.fixedDepth:
      case TimeControlKind.fixedNodes:
        return false;
      case TimeControlKind.incremental:
        final left = remainingMs(side) - elapsedMs;
        if (left < -kTimeMarginMs) return true;
        var remaining = (left < 0 ? 0 : left) + tc.incrementMs;
        final moves = _movesThisSession[side]! + 1;
        _movesThisSession[side] = moves;
        final period = tc.movesPerSession;
        if (period != null && moves % period == 0) remaining += tc.baseMs;
        _remainingMs[side] = remaining;
        return false;
    }
  }

  static int _atLeastOne(int ms) => ms < 1 ? 1 : ms;
}

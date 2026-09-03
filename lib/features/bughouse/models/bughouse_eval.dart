import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'bughouse_state.dart';

/// How the offset in [BughouseCalibration] was arrived at, weakest last.
enum BughouseCalibrationSource {
  /// Both teams were searched from this position, so the offset is measured
  /// here and cancels exactly.
  measured,

  /// Carried over from the last position where both teams had a move. The
  /// offset moves slowly, so this is a good approximation for a ply or two.
  carried,

  /// Nothing has been measured yet, so the offset is the one the opening
  /// position gives. Only ever seen before the first pass finishes, or in a
  /// position loaded straight into a state where one team holds both moves.
  assumed,
}

/// What has to be taken out of Hivemind's score before it means anything.
///
/// Hivemind reports `180·tan(1.56·Q)` of an MCTS value, and that value is not
/// an evaluation of the position alone: it carries a large offset that the
/// network reads mostly off its `TimeAdvantage` input. Measured on this
/// machine, the bit alone is worth about ±0.58 of Q — roughly the difference
/// between "level" and "winning" — so a *balanced* position reads about −0.58
/// from both seats when neither team may sit, and about ±0.58 when one may.
///
/// The offset is **not a constant**. It is the network's estimate of what the
/// clock advantage is worth *in this position*, so it is large in a piece-rich
/// opening and small in a bare endgame. Measured across exactly symmetric
/// two-board positions (identical FEN on both boards, so the true value is 0
/// by symmetry) it ranged from −0.31 to −0.67 of Q — which, subtracted as one
/// fixed number, mis-reported a dead-drawn king-and-pawn ending as more than a
/// pawn up.
///
/// So it is measured rather than assumed. Writing each team's reported value
/// as `q = ±advantage + offset`, two searches of the same position give
///
///     offset    = (qOurs + qTheirs) / 2
///     advantage = (qOurs − qTheirs) / 2
///
/// and the pane already searches both teams on every pass, so this costs
/// nothing. It also handles the asymmetric case for free: when we may sit and
/// they may not, the two searches genuinely agree (+0.58 / −0.58), the offset
/// comes out at zero, and the clock advantage stays in the advantage where it
/// belongs instead of being subtracted away.
@immutable
class BughouseCalibration {
  const BughouseCalibration({required this.offsetQ, required this.source});

  /// The offset to remove, in Q units.
  final double offsetQ;

  final BughouseCalibrationSource source;

  /// What the `TimeAdvantage` bit alone is worth to the network, in Q.
  ///
  /// Measured: a balanced position reads cp −230 with the option off and
  /// +230 with it on, from either seat, at every node count tried, which is
  /// `atan(230/180)/1.56` either way.
  static const double sitBitQ = 0.5814;

  /// The offset a level position would give under a stance pair, for use
  /// before anything has been measured.
  ///
  /// Each team reads its own bit as ±[sitBitQ], and the offset is the average
  /// of the two — so it is −[sitBitQ] when neither team may sit and zero when
  /// exactly one may. That is a rule derived from the same measurement rather
  /// than a second magic number.
  factory BughouseCalibration.assumed({
    required bool weMaySit,
    required bool theyMaySit,
  }) => BughouseCalibration(
    offsetQ:
        ((weMaySit ? sitBitQ : -sitBitQ) + (theyMaySit ? sitBitQ : -sitBitQ)) /
        2,
    source: BughouseCalibrationSource.assumed,
  );

  /// The offset both searches of one position agree on.
  ///
  /// Null when either side is a mate score, which carries no usable value —
  /// the caller keeps whatever it had.
  static BughouseCalibration? measure(
    BughouseInfo? ours,
    BughouseInfo? theirs,
  ) {
    if (ours == null || theirs == null) return null;
    if (ours.mateIn != null || theirs.mateIn != null) return null;
    return BughouseCalibration(
      offsetQ: (ours.q + theirs.q) / 2,
      source: BughouseCalibrationSource.measured,
    );
  }

  /// The same offset, remembered from an earlier position.
  BughouseCalibration get asCarried =>
      source == BughouseCalibrationSource.carried
      ? this
      : BughouseCalibration(
          offsetQ: offsetQ,
          source: BughouseCalibrationSource.carried,
        );

  /// A sentence for the tooltip: where this number's zero came from.
  String get note => switch (source) {
    BughouseCalibrationSource.measured =>
      'Zero is measured here, from both teams\' searches.',
    BughouseCalibrationSource.carried =>
      'Zero is carried from the last position where both teams had a move.',
    BughouseCalibrationSource.assumed =>
      'Zero is assumed from the opening position — no measurement yet.',
  };

  @override
  bool operator ==(Object other) =>
      other is BughouseCalibration &&
      other.offsetQ == offsetQ &&
      other.source == source;

  @override
  int get hashCode => Object.hash(offsetQ, source);
}

/// One evaluation, always from our team's seat.
///
/// Held as an [advantage] in Q rather than as a string, so that turning it
/// around for the other team is arithmetic rather than editing a `+` into a
/// `-` — and so the printed number and the percentage beside it cannot
/// disagree, because both are read off this one value.
@immutable
class BughouseEval {
  const BughouseEval({
    required this.advantage,
    required this.source,
    this.mateIn,
    this.borrowed = false,
  });

  /// Reads one search's line against the offset that applies to it.
  factory BughouseEval.of(
    BughouseInfo info,
    BughouseCalibration calibration, {
    bool borrowed = false,
  }) => BughouseEval(
    advantage: info.mateIn != null
        ? 0
        : (info.q - calibration.offsetQ).clamp(-1.0, 1.0),
    mateIn: info.mateIn,
    source: calibration.source,
    borrowed: borrowed,
  );

  /// How far above level this position is for our team, in Q units: 0 is
  /// level, +1 is won. Zero when [mateIn] carries the answer instead.
  final double advantage;

  /// Moves to mate, our team's sign. Null for an ordinary score.
  final int? mateIn;

  final BughouseCalibrationSource source;

  /// Whether this was read off the opponents' search because our team had no
  /// move to search.
  final bool borrowed;

  /// The same evaluation from the other side of the table.
  BughouseEval get flipped => BughouseEval(
    advantage: -advantage,
    mateIn: mateIn == null ? null : -mateIn!,
    source: source,
    borrowed: borrowed,
  );

  /// The number to print, on the engine's own scale with its offset removed.
  ///
  /// The tangent is put back so the figure lands in the range a reader of
  /// engine output expects, and it is applied to the *shifted* value rather
  /// than subtracting the offset from the raw score. Those are not the same
  /// operation: the tangent is about two and a half times steeper at the
  /// offset than it is at zero, so taking the offset out afterwards inflated
  /// every advantage — and by a different factor under each clock stance, so
  /// the same position moved when only the stance changed.
  ///
  /// Still not pawns. It is Hivemind's scale, re-centred.
  String get label {
    final mate = mateIn;
    if (mate != null) return mate >= 0 ? '#$mate' : '#-${-mate}';
    final hundredths = (score * 100).round();
    if (hundredths == 0) return '0.00';
    final sign = hundredths > 0 ? '+' : '-';
    return '$sign${(hundredths.abs() / 100).toStringAsFixed(2)}';
  }

  /// [label] as a number. Clamped before the tangent, which runs away to
  /// infinity at ±1 — past about ±10 the distinction is "winning" either way,
  /// and a mate prints as a mate.
  double get score =>
      _tangentScale * math.tan(_tangentRate * advantage.clamp(-0.9, 0.9)) / 100;

  /// Our team's expected score as a percentage: 50 is level, 100 is won.
  ///
  /// Linear in [advantage], which is the engine's own value with its offset
  /// removed, so a gain and a loss of the same size read as the same distance
  /// from 50. The piecewise map this replaces was anchored on a level point of
  /// −0.58, which left less than a third as much room below level as above it:
  /// a queen up read +5% and a queen down −16%.
  double get winPercent {
    final mate = mateIn;
    if (mate != null) return mate >= 0 ? 100.0 : 0.0;
    return (50 * (1 + advantage)).clamp(0.0, 100.0);
  }

  /// [winPercent] as a person reads it — `58%`.
  String get winLabel => '${winPercent.round()}%';

  static const double _tangentScale = 180.0;
  static const double _tangentRate = 1.56;
}

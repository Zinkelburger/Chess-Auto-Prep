/// Flaw attribution tags for mined tactics.
///
/// Taxonomy ported from FlawChess (`app/services/flaws_service.py`,
/// AGPL-3.0, github.com/flawchess/flawchess): each mined mistake carries at
/// most one tag per family, all orthogonal —
///
/// - impact: `reversed` (winning → losing) / `squandered` (near-decisive →
///   roughly even), outcome-independent, most-severe-wins;
/// - opportunity: `miss` (your error came right after the opponent's) /
///   `lucky` (a blunder the opponent failed to punish);
/// - phase: `opening` / `middlegame` / `endgame`;
/// - tempo: `low-clock` / `hasty` / `unrushed`, absent entirely when the
///   game has no clock data ("couldn't measure" ≠ "didn't rush").
///
/// All expected-score inputs use the miner's winning-chance scale
/// ([-1, 1], Lichess sigmoid); expected score ES = (wc + 1) / 2.  A ≥ 0.2
/// winning-chance swing equals FlawChess's ≥ 10-ES-point mistake floor.
library;

import '../../../utils/game_phase.dart';

/// Winning-chance rise across an opponent move that marks it a mistake or
/// worse — same scale and value as the miner's own `?` threshold.
const double kOpponentMistakeWcDelta = 0.2;

/// Impact-ladder anchors on the expected-score (0–1) scale: the Lichess
/// sigmoid of +2.0 / −2.0 / +3.0 / +1.0 pawns.
const double kReversedEntryEs = 0.6762;
const double kReversedExitEs = 0.3238;
const double kSquanderedEntryEs = 0.7511;
const double kSquanderedExitEs = 0.5910;

/// Tempo thresholds: relative to base time when known, absolute fallbacks
/// otherwise.  A 5-second move is hasty in classical but normal in bullet.
const double kLowClockFraction = 0.05;
const double kLowClockAbsSeconds = 30.0;
const double kHastyFraction = 0.01;
const double kHastyAbsSeconds = 5.0;

double _es(double wc) => (wc + 1) / 2;

/// Assemble the ordered tag list for one mined user mistake.
///
/// [wcBefore]/[wcAfter]: winning chance (user perspective) before/after the
/// user's move.  [wcAfterPrevUserMove]: after the user's previous move
/// (null at their first move).  [wcBeforeNextUserMove]: before their next
/// move (null when the game ended first).  [userLost] feeds the
/// end-of-game `lucky` rule: a blunder followed by resigning/flagging is a
/// loss, not an escape.  Clock inputs may all be null (no tempo tag).
List<String> buildFlawTags({
  required bool isBlunder,
  required double wcBefore,
  required double wcAfter,
  required double? wcAfterPrevUserMove,
  required double? wcBeforeNextUserMove,
  required bool userLost,
  required String fenBefore,
  double? clockAfterSeconds,
  double? moveTimeSeconds,
  int? baseTimeSeconds,
}) {
  final tags = <String>[];

  final impact = classifyImpact(_es(wcBefore), _es(wcAfter));
  if (impact != null) tags.add(impact);

  // miss: the opponent's preceding move raised our winning chance by a
  // mistake-sized amount — they handed us something and we erred anyway.
  if (wcAfterPrevUserMove != null &&
      wcBefore - wcAfterPrevUserMove >= kOpponentMistakeWcDelta) {
    tags.add('miss');
  }

  // lucky: a blunder whose immediate opponent reply was itself an error
  // (our winning chance bounced back).  Blunders only — tagging mistakes
  // too floods the list.  End of game counts only when we didn't lose.
  if (isBlunder) {
    final lucky = wcBeforeNextUserMove != null
        ? wcBeforeNextUserMove - wcAfter >= kOpponentMistakeWcDelta
        : !userLost;
    if (lucky) tags.add('lucky');
  }

  tags.add(classifyGamePhase(fenBefore).name);

  final tempo = classifyTempo(
    moveTimeSeconds: moveTimeSeconds,
    clockAfterSeconds: clockAfterSeconds,
    baseTimeSeconds: baseTimeSeconds,
  );
  if (tempo != null) tags.add(tempo);

  return tags;
}

/// Outcome-independent impact ladder, most-severe-wins: a 0.90 → 0.25 swing
/// is only `reversed`, never both.  Inclusive boundaries (≥ entry, ≤ exit).
String? classifyImpact(double esBefore, double esAfter) {
  if (esBefore >= kReversedEntryEs && esAfter <= kReversedExitEs) {
    return 'reversed';
  }
  if (esBefore >= kSquanderedEntryEs && esAfter <= kSquanderedExitEs) {
    return 'squandered';
  }
  return null;
}

/// At most one tempo tag, or null when clock data is unavailable — there is
/// no fallback tag, so downstream displays must show an unmeasured
/// remainder rather than normalizing the three measured buckets to 100%.
///
/// Priority: low-clock (forced haste) > hasty (self-inflicted) > unrushed.
String? classifyTempo({
  required double? moveTimeSeconds,
  required double? clockAfterSeconds,
  required int? baseTimeSeconds,
}) {
  if (clockAfterSeconds == null || moveTimeSeconds == null) return null;

  final double lowClockThreshold;
  final double hastyThreshold;
  if (baseTimeSeconds != null && baseTimeSeconds > 0) {
    lowClockThreshold = baseTimeSeconds * kLowClockFraction;
    hastyThreshold = baseTimeSeconds * kHastyFraction;
  } else {
    lowClockThreshold = kLowClockAbsSeconds;
    hastyThreshold = kHastyAbsSeconds;
  }

  if (clockAfterSeconds < lowClockThreshold) return 'low-clock';
  if (moveTimeSeconds < hastyThreshold) return 'hasty';
  return 'unrushed';
}

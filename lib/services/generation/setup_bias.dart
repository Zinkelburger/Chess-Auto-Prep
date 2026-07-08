/// Preferred-setup bias — play a consistent system when it's sound.
///
/// The user names the moves of a setup they want to play whenever possible
/// (e.g. the 150 Attack vs the Pirc: "Be3 Qd2 f3 O-O-O h4 Nh3").  Two
/// mechanisms use it:
///
///  1. **Candidate injection** (tree build): quiet system moves are often
///     missing from Maia/MultiPV top-N, so any legal setup move is
///     evaluated and added as a candidate, subject to the normal
///     eval-loss window.
///  2. **Selection tie-break** ([RepertoireSelector]): within
///     `setupToleranceCp` of the best child eval, a move that advances
///     the setup is preferred over the plain expectimax pick.
///
/// The bias never touches expectimax values — it only constrains which
/// candidate the argmax picks, exactly like `maxEvalLossCp` already does.
/// When the opponent makes consistency expensive (e.g. ...Ng4 hitting the
/// Be3 bishop), every setup continuation falls outside the tolerance and
/// selection deviates automatically.
library;

/// Normalize SAN for matching: strip check/mate marks and annotations.
String normalizeSetupSan(String san) =>
    san.replaceAll(RegExp(r'[+#!?]+$'), '').trim();

/// Parse a space/comma-separated SAN list into a normalized set.
Set<String> parseSetupMoves(String raw) {
  if (raw.trim().isEmpty) return const {};
  return {
    for (final tok in raw.split(RegExp(r'[,\s]+')))
      if (normalizeSetupSan(tok).isNotEmpty) normalizeSetupSan(tok),
  };
}

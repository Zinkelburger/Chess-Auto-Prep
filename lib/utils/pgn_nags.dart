/// Numeric Annotation Glyphs — the `$1`..`$6` a PGN uses to say `!`, `?`, `!?`.
///
/// Split out of `pgn_comment_utils.dart`, which is otherwise about parsing
/// `[%tag …]` tokens out of comment text. NAGs are a different part of the
/// format and, unlike the rest of that file, they carry presentation: a NAG
/// has a colour, which is why a pure parsing utility was importing the theme.
/// Seven of the eight files that touched NAGs wanted nothing else from the
/// old module.
library;

import 'dart:ui' show Color;

import '../theme/app_colors.dart';

// ---------------------------------------------------------------------------
// NAG (Numeric Annotation Glyph) constants and helpers
// ---------------------------------------------------------------------------

/// Standard move-quality NAG definitions following PGN spec.
/// Order: best-to-worst (toolbar display order).
class NagInfo {
  final int id;
  final String symbol;
  final String name;
  final Color color;
  const NagInfo(this.id, this.symbol, this.name, this.color);
}

/// The 6 standard move-quality NAGs.
///
/// The palette is a single good→bad temperature ramp (teal → green → lime →
/// amber → orange → red) chosen for the app's dark surface: every tone clears
/// ~7:1 on #121212. (The previous values were Lichess's *light-theme* set —
/// its #168226 brilliant-green was nearly invisible on dark, and its magenta
/// `!?` read as an alert rather than "interesting". The green/red have since
/// been lifted a step — #66BB6A/#EF5350 sat at ~7.9:1/~5.4:1, and the red in
/// particular was hard to read at movetext sizes.)
const kMoveNags = [
  NagInfo(3, '!!', 'Brilliant', AppColors.nagBrilliant),
  NagInfo(1, '!', 'Good move', AppColors.nagGood),
  NagInfo(5, '!?', 'Interesting', AppColors.nagInteresting),
  NagInfo(6, '?!', 'Dubious', AppColors.nagDubious),
  NagInfo(2, '?', 'Mistake', AppColors.nagMistake),
  NagInfo(4, '??', 'Blunder', AppColors.nagBlunder),
];

/// Lookup NAG info by ID. Returns null for unknown NAGs.
NagInfo? nagInfoById(int id) {
  for (final nag in kMoveNags) {
    if (nag.id == id) return nag;
  }
  return null;
}

/// Standard PGN glyphs that annotate the *position* rather than the move —
/// what an annotator writes after the move instead of `!`/`?`.
///
/// Only [kMoveNags] (ids 1–6) are editable in the app, because only those are
/// mutually exclusive move verdicts. These are read-only: they arrive in
/// imported PGNs (Lichess studies, Chessable and ChessBase exports) and used to
/// vanish from the movetext because the renderers filtered to 1–6. A symbol is
/// the whole content of the annotation, so dropping it drops the annotation.
const Map<int, String> kPositionNagSymbols = {
  7: '□', // forced move — only move
  10: '=', // drawish position
  11: '=', // equal chances, quiet position
  13: '∞', // unclear position
  14: '⩲', // White stands slightly better
  15: '⩱', // Black stands slightly better
  16: '±', // White has a moderate advantage
  17: '∓', // Black has a moderate advantage
  18: '+−', // White has a decisive advantage
  19: '−+', // Black has a decisive advantage
  22: '⨀', // White is in zugzwang
  23: '⨀', // Black is in zugzwang
  32: '⟳', // White has a lasting development advantage
  33: '⟳', // Black has a lasting development advantage
  36: '↑', // White has the initiative
  37: '↑', // Black has the initiative
  40: '→', // White has the attack
  41: '→', // Black has the attack
  44: '=∞', // White has compensation for material
  45: '=∞', // Black has compensation for material
  132: '⇆', // White has counterplay
  133: '⇆', // Black has counterplay
  138: '⊕', // White is in time trouble
  139: '⊕', // Black is in time trouble
  140: '∆', // with the idea
  146: 'N', // novelty
};

/// Get the display symbol for a NAG ID. Falls back to `\$N` for ids that have
/// no conventional glyph, so an unrecognised annotation still shows up rather
/// than disappearing.
String nagSymbol(int id) =>
    nagInfoById(id)?.symbol ?? kPositionNagSymbols[id] ?? '\$$id';

/// Every NAG on [nags] as one glyph run, in the order the PGN wrote them —
/// quality verdicts and positional assessments alike (`Nf3!⩲`). Empty when
/// there are none.
///
/// Contrast [qualityNagSuffix], which is the *editable* subset (ids 1–6) and
/// exists for the annotation toolbar. Movetext display wants this one: a
/// reader loses information when `$14` is silently swallowed.
String allNagSuffix(List<int>? nags) {
  if (nags == null || nags.isEmpty) return '';
  final buf = StringBuffer();
  for (final n in nags) {
    buf.write(nagSymbol(n));
  }
  return buf.toString();
}

/// Get the color for a NAG ID. Returns a neutral grey for unknown NAGs.
Color nagColor(int id) => nagInfoById(id)?.color ?? AppColors.onSurfaceMuted;

/// The primary move-quality NAG (ids 1–6) on [nags], or null when none is set.
/// Drives the move's colour in the movetext. Only one quality NAG is ever
/// present at a time (they are mutually exclusive — see [toggleQualityNag]).
int? primaryQualityNag(List<int>? nags) {
  if (nags == null) return null;
  for (final n in nags) {
    if (n >= 1 && n <= 6) return n;
  }
  return null;
}

/// The concatenated glyph symbols (e.g. `!?`) for the move-quality NAGs (ids
/// 1–6) on [nags], in list order. Empty when none is set. This is the suffix
/// appended after the SAN in the movetext (`Nf3` → `Nf3!?`).
String qualityNagSuffix(List<int>? nags) {
  if (nags == null) return '';
  final buf = StringBuffer();
  for (final n in nags) {
    if (n >= 1 && n <= 6) buf.write(nagSymbol(n));
  }
  return buf.toString();
}

/// Toggle move-quality NAG [nagId] on a move's [current] NAG list, returning
/// the new list. The six quality glyphs (ids 1–6) are mutually exclusive:
/// setting one clears the others, and setting the one already present removes
/// it. Non-quality NAGs are preserved. The result may be empty (callers store
/// `null` for an empty NAG list).
List<int> toggleQualityNag(List<int>? current, int nagId) {
  final others = [
    for (final n in current ?? const <int>[])
      if (n < 1 || n > 6) n,
  ];
  final alreadyOn = (current ?? const <int>[]).contains(nagId);
  return <int>[if (!alreadyOn && nagId >= 1 && nagId <= 6) nagId, ...others];
}

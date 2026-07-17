/// Unified palette for Chess Auto Prep.
///
/// One name per distinct value: reuse an existing token (or alias it) before
/// minting a new hex. Contrast targets assume the darkest surface [surface]
/// (#121212); anything meant for smaller text must clear WCAG AA (4.5:1).
///
/// Muted variants (`*Muted`) are hand-tuned desaturations toward mid-gray
/// (#8A8A8A) that still clear ~4.5:1 on [surface] — used by the analysis
/// tables, where columns are **bright by default** and tapping a column
/// header dims it (see [EngineSettings.mutedAnalysisColumns]).
library;

import 'package:flutter/material.dart';

abstract final class AppColors {
  // ── Surfaces ─────────────────────────────────────────────────────────────

  static const surface = Color(0xFF121212);
  static const surfaceElevated = Color(0xFF1E1E1E);
  static const surfaceContainer = Color(0xFF2A2A2A);

  /// Recessed chip/track/snackbar fill, one step above [surfaceContainer].
  static const surfaceInset = Color(0xFF303030);

  /// Default filled/elevated button fill (see main.dart button themes).
  static const buttonSurface = Color(0xFF404040);

  /// ColorScheme.secondary — slider tracks, switches, selection chrome.
  static const surfaceHighlight = Color(0xFF606060);

  // ── Ink hierarchy (text/icons on the dark surfaces) ──────────────────────

  /// Canonical body ink (16.7:1 on [surface]). [AppTextStyles.ink] and the
  /// PGN movetext tokens alias this — there is exactly one "white" in the app.
  static const ink = Color(0xFFF2F2F2);

  /// One step softer than [ink] (15.3:1) — subtitles, move numbers.
  static const inkSoft = Color(0xFFE8E8E8);

  /// Secondary text/icons that must stay comfortably readable (9.6:1).
  static const onSurfaceSoft = Color(0xFFBDBDBD);

  /// Muted labels / chrome — the AA floor workhorse (7.0:1).
  static const onSurfaceMuted = Color(0xFF9E9E9E);

  /// Dimmest legible ink (5.4:1). The old #757575 failed AA (4.07:1) and is
  /// now reserved for [onSurfaceDisabled].
  static const onSurfaceDim = Color(0xFF8A8A8A);

  /// Disabled controls ONLY (4.07:1 — intentionally sub-AA; WCAG exempts
  /// disabled UI). Never use for readable copy.
  static const onSurfaceDisabled = Color(0xFF757575);

  // ── Lines, overlays, states ──────────────────────────────────────────────

  /// Hairline divider as an alpha wash (composites over any surface).
  static const divider = Color(0x24FFFFFF);

  /// Solid hairline border/outline (use where alpha washes would stack).
  static const outline = Color(0xFF616161);

  /// Row-hover wash for tables/lists.
  static const hoverOverlay = Color(0x0CFFFFFF);

  /// Zebra stripe for alternating list rows.
  static const rowStripe = Color(0x07FFFFFF);

  /// Modal / loading scrim.
  static const scrim = Color(0x42000000);

  /// Blocking scrim for full-surface lock overlays (content must be
  /// unmistakably inert underneath, so much darker than [scrim]).
  static const scrimHeavy = Color(0x99000000);

  /// Text/icons over photos, boards, and black scrims (fullscreen chrome).
  static const overlayInk = Color(0xDCFFFFFF);
  static const overlayInkMuted = Color(0x99FFFFFF);

  /// Drop shadow for floating previews/popups (Material's 54% black).
  static const shadow = Color(0x8A000000);

  /// True-black backdrop for immersive fullscreen views (game viewer).
  /// The only sanctioned pure-black surface; edge-fade chrome derives from
  /// it via `withAlpha`.
  static const backdrop = Color(0xFF000000);

  // ── Canonical semantic colors (one name per distinct value) ─────────────

  static const success = Color(0xFF66BB6A);
  static const danger = Color(0xFFEF5350);
  static const warning = Color(0xFFFFCA28);
  static const info = Color(0xFF42A5F5);

  /// Softer positive step between [success] and neutral (9.3:1).
  static const successSoft = Color(0xFF81C784);

  static const successMuted = Color(0xFF7A9E82);
  static const dangerMuted = Color(0xFF9E7A7A);
  static const warningMuted = Color(0xFF9A8868);
  static const successSoftMuted = Color(0xFF8FAF92);

  /// Solid fills for filled buttons/banners carrying the semantic meaning.
  static const successSurface = Color(0xFF2E7D32);
  static const dangerSurface = Color(0xFFC62828);
  static const warningSurface = Color(0xFFF57F17);

  /// Ink for text/icons ON bright/mid-tone semantic fills. Named for the
  /// dominant case ([warning]/[warningSurface]/[starAccent], where white is
  /// ~2.6:1), but correct on any of the semantic fills — white fails AA on
  /// [success], [info], and [danger] fills too; this dark ink clears it.
  static const onWarning = Color(0xDE000000);

  /// Low-alpha status washes for rows, banners, and icon chips.
  static const successTint = Color(0x2666BB6A);
  static const dangerTint = Color(0x26EF5350);
  static const warningTint = Color(0x26FFCA28);
  static const infoTint = Color(0x2642A5F5);

  /// App-wide selected/active accent (tabs, active zone chrome). Also the
  /// legacy repertoire "mainline" hue — see [pgnMainLine].
  static const accent = Color(0xFF26A69A);

  /// Star ratings, trophies, favorites. Pair text/icons ON it with
  /// [onWarning].
  static const starAccent = Color(0xFFFFC107);

  /// Empty star / inactive rating step.
  static const starEmpty = onSurfaceDim;

  // ── Chess eval (centipawns) ─────────────────────────────────────────────

  static const evalPositive = success;
  static const evalNegative = danger;
  static const evalNeutral = Color(0xFFB0B0B0);

  static const evalPositiveMuted = successMuted;
  static const evalNegativeMuted = dangerMuted;
  static const evalNeutralMuted = Color(0xFF8A8A8A);

  static const _cpEvalThreshold = 50;
  static const _cpEvalBgStrongCp = 100;
  static const _cpEvalBgMildCp = 30;

  static Color cpEval(
    int cp, {
    bool muted = false,
    int threshold = _cpEvalThreshold,
  }) {
    if (cp > threshold) {
      return muted ? evalPositiveMuted : evalPositive;
    }
    if (cp < -threshold) {
      return muted ? evalNegativeMuted : evalNegative;
    }
    return muted ? evalNeutralMuted : evalNeutral;
  }

  /// Cell backgrounds for eval columns: a green→neutral→red ramp of five
  /// steps (strong+/mild+/neutral/mild−/strong−), pre-blended against
  /// [surface] rather than alpha washes so table rows never stack tints.
  static Color cpEvalBg(int cp, {bool muted = false}) {
    if (muted) {
      if (cp > _cpEvalBgStrongCp) return const Color(0xFF2A3530);
      if (cp > _cpEvalBgMildCp) return const Color(0xFF252E2A);
      if (cp > -_cpEvalBgMildCp) return const Color(0xFF2C2C2C);
      if (cp > -_cpEvalBgStrongCp) return const Color(0xFF302825);
      return const Color(0xFF302525);
    }
    if (cp > _cpEvalBgStrongCp) return const Color(0xFF1B3D1F);
    if (cp > _cpEvalBgMildCp) return const Color(0xFF1E3320);
    if (cp > -_cpEvalBgMildCp) return const Color(0xFF2C2C2C);
    if (cp > -_cpEvalBgStrongCp) return const Color(0xFF3D2525);
    return const Color(0xFF4A2020);
  }

  // ── Analysis sources ────────────────────────────────────────────────────

  static const stockfish = Color(0xFFFFB74D);
  static const expectimax = Color(0xFF4DB6AC);
  static const maia = Color(0xFFCE93D8);
  static const lichessDb = Color(0xFF4DD0E1);

  static const stockfishMuted = Color(0xFFB8A67A);
  static const expectimaxMuted = Color(0xFF7A9E9A);
  static const maiaMuted = Color(0xFF9A8FAD);
  static const lichessDbMuted = Color(0xFF7E9DB5);

  static Color stockfishColor({bool muted = false}) =>
      muted ? stockfishMuted : stockfish;
  static Color expectimaxColor({bool muted = false}) =>
      muted ? expectimaxMuted : expectimax;
  static Color maiaColor({bool muted = false}) => muted ? maiaMuted : maia;
  static Color lichessDbColor({bool muted = false}) =>
      muted ? lichessDbMuted : lichessDb;

  /// Engine-line / eval readout text inside prose panels (blueGrey 300).
  static const engineLine = Color(0xFF90A4AE);

  // ── PGN movetext ────────────────────────────────────────────────────────

  /// Legacy repertoire accent for mainline-flavored *chrome* (alias of
  /// [accent]). Movetext itself no longer uses it — moves, sidelines, and
  /// branch chips all render in the single near-white ink below.
  static const pgnMainLine = accent;

  /// Background of movetext panels (the repertoire editor pane). Pure black:
  /// movetext ink on it hits maximum contrast.
  static const pgnSurface = Color(0xFF000000);

  // PGN text policy: pure white on pure black, no tinted or dimmed tones.
  // Hierarchy comes from weight/italics/pills/rows, never from graying text.

  /// Movetext ink: pure white (21:1 on [pgnSurface]). Sidelines use structure
  /// (parens + line breaks), not a separate hue — see `PgnTextStyles`.
  static const pgnMove = Color(0xFFFFFFFF);

  /// Move numbers (`1.` / `2...`) — same white as moves; dimming them ever
  /// read as "disabled gray".
  static const pgnMoveNumber = pgnMove;

  /// Current navigation position — the sole "you are here" hue accent.
  static const pgnMoveCurrent = info;

  /// Fill of the current-move pill (pairs with [pgnMoveCurrent] border).
  static const pgnMoveCurrentBg = Color(0xFF1F6FB2);

  /// Text on the current-move / active pill.
  static const pgnMoveCurrentFg = Color(0xFFFFFFFF);

  /// Sideline / variation SAN and brackets — same ink as mainline; distinguish
  /// with `( )` and own-row layout, not mint/teal.
  static const pgnVariation = pgnMove;

  /// Solitaire / scratch analysis moves — same white; the ephemeral pill fill
  /// and row placement distinguish unsaved analysis from repertoire moves.
  static const pgnEphemeralMove = pgnMove;

  /// Fill of the current ephemeral node pill.
  static const pgnEphemeralBg = Color(0xFF42607D);

  /// Move comments — same ink as moves (italic via `PgnTextStyles.comment`).
  static const pgnComment = pgnMove;

  /// Near-black fill for bordered comment blocks on [surface].
  static const pgnCommentBlockBg = Color(0xFF181818);

  // ── Coherence / traps / scores ──────────────────────────────────────────

  static const coherenceHigh = success;
  static const coherenceMid = warning;
  static const coherenceLow = danger;

  static const coherenceHighMuted = successMuted;
  static const coherenceMidMuted = Color(0xFF9A9468);
  static const coherenceLowMuted = dangerMuted;

  static const _coherenceHighThreshold = 0.7;
  static const _coherenceMidThreshold = 0.4;
  static const _trapScoreHighThreshold = 0.5;
  static const _trapScoreMidThreshold = 0.2;
  static const _winProbStrongThreshold = 0.65;
  static const _winProbMidThreshold = 0.55;
  static const _winProbNeutralThreshold = 0.45;
  static const _easeHighThreshold = 0.8;
  static const _easeMidThreshold = 0.6;
  static const _cplExcellentThreshold = 5;
  static const _cplGoodThreshold = 15;
  static const _cplFairThreshold = 30;

  static Color coherence(double c, {bool muted = false}) {
    if (c >= _coherenceHighThreshold) {
      return muted ? coherenceHighMuted : coherenceHigh;
    }
    if (c >= _coherenceMidThreshold) {
      return muted ? coherenceMidMuted : coherenceMid;
    }
    return muted ? coherenceLowMuted : coherenceLow;
  }

  static Color trapScore(double score, {bool muted = false}) {
    if (score >= _trapScoreHighThreshold) {
      return muted ? dangerMuted : danger;
    }
    if (score >= _trapScoreMidThreshold) {
      return muted ? warningMuted : warning;
    }
    return muted ? coherenceMidMuted : coherenceMid;
  }

  static Color winProbability(double v, {bool muted = false}) {
    if (v > _winProbStrongThreshold) {
      return muted ? evalPositiveMuted : evalPositive;
    }
    if (v > _winProbMidThreshold) {
      return muted ? successSoftMuted : successSoft;
    }
    if (v > _winProbNeutralThreshold) {
      return muted ? evalNeutralMuted : evalNeutral;
    }
    return muted ? warningMuted : warning;
  }

  static Color ease(double ease, {bool muted = false}) {
    if (ease > _easeHighThreshold) {
      return muted ? evalPositiveMuted : evalPositive;
    }
    if (ease > _easeMidThreshold) {
      return muted ? coherenceMidMuted : coherenceMid;
    }
    return muted ? warningMuted : warning;
  }

  static Color cpl(double cpl, {bool muted = false}) {
    if (cpl < _cplExcellentThreshold) {
      return muted ? evalPositiveMuted : evalPositive;
    }
    if (cpl < _cplGoodThreshold) {
      return muted ? successSoftMuted : successSoft;
    }
    if (cpl < _cplFairThreshold) {
      return muted ? coherenceMidMuted : coherenceMid;
    }
    return muted ? warningMuted : warning;
  }

  // ── Game-analysis move classification (chart + move list) ───────────────

  static const moveClassBlunder = Color(0xFFDB3B21);
  static const moveClassMistake = Color(0xFFE69F00);
  static const moveClassInaccuracy = Color(0xFF56B4E9);
  static const moveClassInteresting = Color(0xFF9C27B0);

  // ── NAG glyph colors ($1–$6 annotations rendered in comments) ───────────

  static const nagBrilliant = Color(0xFF168226);
  static const nagGood = Color(0xFF4CAF50);
  static const nagInteresting = Color(0xFFEA45D8);

  /// `?!` and `?` share the move-classification hues by design.
  static const nagDubious = moveClassInaccuracy;
  static const nagMistake = moveClassMistake;
  static const nagBlunder = Color(0xFFDF5353);

  // ── Game-analysis eval chart (game_analysis_chart.dart) ─────────────────

  static const chartEvalLine = Color(0xFFD08030);
  static const chartMedianLine = Color(0xFF6FBF8F);

  /// Decorative gridline — same hex as [onSurfaceDisabled], distinct role
  /// (non-text chrome, so sub-AA is acceptable).
  static const chartGridline = Color(0xFF757575);

  /// Area fills for the white/black advantage regions of the eval chart.
  static const chartAreaWhite = Color(0xB3FFFFFF);
  static const chartAreaBlack = Color(0xFF303030);

  // ── Eval-tree node fills (Repertoire → Tree tab) ─────────────────────────
  // Muted, desaturated fills hand-tuned so white node labels stay legible;
  // classification helpers live in lib/features/eval_tree/tree_colors.dart.

  static const treeNodeOurMoveRepertoire = Color(0xFF3D5245);
  static const treeNodeOurMove = Color(0xFF354840);
  static const treeNodeOpponentMove = Color(0xFF3A4248);
  static const treeNodeBlunder = Color(0xFF6E4545);
  static const treeNodeBigMistake = Color(0xFF6E4F3D);
  static const treeNodeMistake = Color(0xFF6E5A3D);
  static const treeNodeInaccuracy = Color(0xFF6E6640);
  static const treeNodeNeutral = Color(0xFF424242);

  /// Accent stroke/glyph marking repertoire moves inside the eval tree.
  static const treeNodeAccentRepertoire = Color(0xFF8A9E9A);

  // ── Tactics mistake severity (?? / ? / ?! / custom) ─────────────────────

  static const mistakeBlunder = danger;
  static const mistakeMistake = Color(0xFFFFA726);
  static const mistakeInaccuracy = warning;
  static const mistakeCustom = info;

  // ── Repertoire coverage status (Lines tab) ──────────────────────────────

  static const coverageCovered = Color(0xFF4CAF50);
  static const coverageShallow = Color(0xFFFFA726);
  static const coverageDeep = info;
  static const coverageUnaccounted = danger;

  // ── Spaced repetition (Train tab) ───────────────────────────────────────

  static const srsNew = info;
  static const srsDue = Color(0xFFFFA726);
  static const srsLearned = success;

  /// Recall-grade buttons on the training results panel.
  static const srsAgain = Color(0xFFE53935);
  static const srsHard = Color(0xFFFB8C00);
  static const srsGood = Color(0xFF1E88E5);
  static const srsEasy = Color(0xFF43A047);

  // ── Audit finding severity (Find Holes / Player Analysis) ───────────────

  static const findingInaccuracy = Color(0xFFFF9800);
  static const findingMissingResponse = info;
  static const findingWeakPosition = Color(0xFFFF5722);
  static const findingUncoveredStrongMove = Color(0xFF00BCD4);
  static const findingPracticalTrap = Color(0xFFE040FB);
  static const findingClash = Color(0xFF9C27B0);

  // ── Trap reply classification (blunder → good) ──────────────────────────

  static const replyBlunder = danger;
  static const replyMistake = Color(0xFFFF9800);
  static const replyInaccuracy = starAccent;
  static const replyAcceptable = onSurfaceMuted;
  static const replyGood = success;

  // ── Platform identity badges ────────────────────────────────────────────

  static const platformChessCom = Color(0xFF4CAF50);
  static const platformLichess = info;
  static const platformImported = Color(0xFFFFA726);

  // ── Board ───────────────────────────────────────────────────────────────

  static const boardLightSquare = Color(0xFFF0D9B5);
  static const boardDarkSquare = Color(0xFFB58863);
  static const boardSelected = Color(0xFFFFFF00);
  static const boardHighlight = Color(0x806496FF);

  /// Canvas stroke for board frames / painted-piece outlines.
  static const boardOutline = Color(0xFF000000);

  /// User annotation brushes (arrows/circles), lichess-style translucents.
  static const boardArrowGreen = Color(0xCC15781B);
  static const boardArrowRed = Color(0xCCCC2222);
  static const boardArrowBlue = Color(0xCC003088);
  static const boardArrowYellow = Color(0xCCE6A800);
  static const boardArrowPurple = Color(0xCC9B59B6);

  // ── Side indicators (playing-as-White / playing-as-Black chips) ─────────

  /// Swatch/fill representing the White side.
  static const sideWhite = Color(0xFFFFFFFF);

  /// Swatch/fill representing the Black side — lifted off pure black so it
  /// reads on dark surfaces; always pair with an [outline] border.
  static const sideBlack = Color(0xFF212121);

  /// Glyphs/text ON a [sideWhite] fill (dark ink, mirrors [onWarning]).
  static const onSideWhite = Color(0xDE000000);

  // ── Win/draw/loss bars (opening explorer, games review) ─────────────────

  static const wdlWhite = Color(0xFFE8E8E8);
  static const wdlDraw = Color(0xFF757575);
  static const wdlBlack = Color(0xFF2B2B2B);

  // ── Filter / slice chips ────────────────────────────────────────────────

  static const chipActiveBg = Color(0xFF1565C0);
  static const chipActiveFg = Color(0xFFE3F2FD);
  static const chipInactiveBg = Color(0xFF424242);
}

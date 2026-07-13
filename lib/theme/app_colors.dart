/// Unified palette for Chess Auto Prep.
///
/// Analysis table columns are **bright by default**. Tap a column header to
/// dim that column (see [EngineSettings.mutedAnalysisColumns]).
library;

import 'package:flutter/material.dart';

abstract final class AppColors {
  // ── Surfaces (also referenced from [main.dart] theme) ───────────────────

  static const surface = Color(0xFF121212);
  static const surfaceElevated = Color(0xFF1E1E1E);
  static const surfaceContainer = Color(0xFF2A2A2A);

  static const onSurfaceMuted = Color(0xFF9E9E9E);
  static const onSurfaceDim = Color(0xFF757575);

  static const divider = Color(0x24FFFFFF);

  // ── Canonical semantic colors (one name per distinct value) ─────────────

  static const success = Color(0xFF66BB6A);
  static const danger = Color(0xFFEF5350);
  static const warning = Color(0xFFFFCA28);

  // ── Chess eval (centipawns) ─────────────────────────────────────────────

  static const evalPositive = success;
  static const evalNegative = danger;
  static const evalNeutral = Color(0xFFB0B0B0);

  static const evalPositiveMuted = Color(0xFF7A9E82);
  static const evalNegativeMuted = Color(0xFF9E7A7A);
  static const evalNeutralMuted = Color(0xFF8A8A8A);

  static const cpEvalThreshold = 50;
  static const cpEvalBgStrongCp = 100;
  static const cpEvalBgMildCp = 30;

  static const coherenceHighThreshold = 0.7;
  static const coherenceMidThreshold = 0.4;

  static const trapScoreHighThreshold = 0.5;
  static const trapScoreMidThreshold = 0.2;

  static const winProbStrongThreshold = 0.65;
  static const winProbMidThreshold = 0.55;
  static const winProbNeutralThreshold = 0.45;

  static const easeHighThreshold = 0.8;
  static const easeMidThreshold = 0.6;

  static const cplExcellentThreshold = 5;
  static const cplGoodThreshold = 15;
  static const cplFairThreshold = 30;

  static Color cpEval(int cp,
      {bool muted = false, int threshold = cpEvalThreshold}) {
    if (cp > threshold) {
      return muted ? evalPositiveMuted : evalPositive;
    }
    if (cp < -threshold) {
      return muted ? evalNegativeMuted : evalNegative;
    }
    return muted ? evalNeutralMuted : evalNeutral;
  }

  static Color cpEvalBg(int cp, {bool muted = false}) {
    if (muted) {
      if (cp > cpEvalBgStrongCp) return const Color(0xFF2A3530);
      if (cp > cpEvalBgMildCp) return const Color(0xFF252E2A);
      if (cp > -cpEvalBgMildCp) return const Color(0xFF2C2C2C);
      if (cp > -cpEvalBgStrongCp) return const Color(0xFF302825);
      return const Color(0xFF302525);
    }
    if (cp > cpEvalBgStrongCp) return const Color(0xFF1B3D1F);
    if (cp > cpEvalBgMildCp) return const Color(0xFF1E3320);
    if (cp > -cpEvalBgMildCp) return const Color(0xFF2C2C2C);
    if (cp > -cpEvalBgStrongCp) return const Color(0xFF3D2525);
    return const Color(0xFF4A2020);
  }

  // ── Analysis sources ────────────────────────────────────────────────────

  static const stockfish = Color(0xFFFFB74D);
  static const expectimax = Color(0xFF4DB6AC);
  static const maia = Color(0xFFCE93D8);
  static const lichessDb = Color(0xFF4DD0E1);
  static const difficulty = warning;

  static const stockfishMuted = Color(0xFFB8A67A);
  static const expectimaxMuted = Color(0xFF7A9E9A);
  static const maiaMuted = Color(0xFF9A8FAD);
  static const lichessDbMuted = Color(0xFF7E9DB5);
  static const difficultyMuted = Color(0xFFB5A078);

  static Color stockfishColor({bool muted = false}) =>
      muted ? stockfishMuted : stockfish;
  static Color expectimaxColor({bool muted = false}) =>
      muted ? expectimaxMuted : expectimax;
  static Color maiaColor({bool muted = false}) => muted ? maiaMuted : maia;
  static Color lichessDbColor({bool muted = false}) =>
      muted ? lichessDbMuted : lichessDb;

  // ── Semantic actions ────────────────────────────────────────────────────

  static const successSurface = Color(0xFF2E7D32);
  static const dangerSurface = Color(0xFFC62828);
  static const warningSurface = Color(0xFFF57F17);

  static const info = Color(0xFF42A5F5);
  static const infoMuted = Color(0xFF7A8FA8);

  static Color infoColor({bool muted = false}) => muted ? infoMuted : info;

  static const pgnMainLine = Color(0xFF26A69A);
  static const pgnMainLineMuted = Color(0xFF6E8E8A);
  static const pgnEphemeral = Color(0xFF7A8FA8);
  static const pgnEphemeralMuted = Color(0xFF5A6578);

  /// Background of movetext panels (the repertoire editor pane). Near-black:
  /// text contrast is maximised on the darkest surface, so movetext gets
  /// [surface]-level darkness rather than the mid-gray [surfaceContainer]
  /// (#2A2A2A), which cost every text tone in the pane ~2 contrast steps.
  static const pgnSurface = Color(0xFF151515);

  /// Default SAN in editable PGN panes. Bright (~14:1 on [surface]) so the
  /// movetext stays readable in glare/sunlight at small sizes.
  static const pgnMove = Color(0xFFDDE6EF);

  /// Move numbers (`1.` / `2...`) — dimmer than moves to keep hierarchy, but
  /// comfortably readable (~9:1 on [surface]; the previous #9AA0A6 at ~6.7:1
  /// still read as "disabled gray" next to the bright SANs).
  static const pgnMoveNumber = Color(0xFFB4BCC6);

  /// Current navigation position — the "you are here" accent. Used as the
  /// bright border/glow around the highlighted move pill.
  static const pgnMoveCurrent = info;

  /// Fill of the current-move pill. Bright enough to read as a solid chip on
  /// the near-black surface (3.55:1) — pairs with [pgnMoveCurrent] border and
  /// [pgnMoveCurrentFg] text for an unmissable "you are here" marker.
  static const pgnMoveCurrentBg = Color(0xFF1F6FB2);

  /// Text sitting on the current-move / active pill (light for legibility on
  /// the blue fill, 4.6:1).
  static const pgnMoveCurrentFg = Color(0xFFE3F2FD);

  /// Explicitly selected move (comment editing, context menu target).
  static const pgnMoveSelectedBg = Color(0xFF1565C0);

  /// Saved sideline / variation text and brackets. A clearly-teal, readable
  /// tone (~10.7:1) so sidelines read as "alternate line", not "disabled".
  static const pgnVariation = Color(0xFFA9CFC9);

  /// On-the-fly analysis moves (distinct from repertoire, not orange).
  /// Brighter than [infoMuted] (~7.5:1 vs 5.5:1) for small-text legibility.
  static const pgnEphemeralMove = Color(0xFF93A9C4);

  /// Fill of the current *ephemeral* (analysis) node pill — a brighter slate
  /// (2.9:1) that stays legible with [pgnMoveCurrentFg] text.
  static const pgnEphemeralBg = Color(0xFF42607D);

  /// Move-comment prose — a warm ivory (~11:1) instead of flat neutral gray.
  /// The warmth is deliberate: moves/numbers are all cool-toned, so prose in a
  /// warm tone separates "annotation text" from "notation" at a glance, and
  /// the alpha-dimmed blockquote/bracket/FEN variants still clear AA.
  static const pgnComment = Color(0xFFD6CDBD);

  /// Solid, near-black fill for bordered comment blocks. Replaces the old
  /// translucent gray wash (which muddied to ~#232323) with a clean panel that
  /// sits just above the movetext surface (#121212) and pairs with the
  /// [pgnComment] accent border. Prose text on it clears ~9.5:1.
  static const pgnCommentBlockBg = Color(0xFF181818);

  static Color pgnMainLineColor({bool muted = false}) =>
      muted ? pgnMainLineMuted : pgnMainLine;
  static Color pgnEphemeralColor({bool muted = false}) =>
      muted ? pgnEphemeralMuted : pgnEphemeral;

  // ── Coherence / traps / scores ──────────────────────────────────────────

  static const coherenceHigh = Color(0xFF66BB6A);
  static const coherenceMid = Color(0xFFFFCA28);
  static const coherenceLow = Color(0xFFEF5350);

  static const coherenceHighMuted = Color(0xFF7A9E82);
  static const coherenceMidMuted = Color(0xFF9A9468);
  static const coherenceLowMuted = Color(0xFF9E7A7A);

  static Color coherence(double c, {bool muted = false}) {
    if (c >= coherenceHighThreshold) {
      return muted ? coherenceHighMuted : coherenceHigh;
    }
    if (c >= coherenceMidThreshold) {
      return muted ? coherenceMidMuted : coherenceMid;
    }
    return muted ? coherenceLowMuted : coherenceLow;
  }

  static Color trapScore(double score, {bool muted = false}) {
    if (score >= trapScoreHighThreshold) {
      return muted ? danger.withValues(alpha: 0.7) : danger;
    }
    if (score >= trapScoreMidThreshold) {
      return muted ? warningMuted : warning;
    }
    return muted ? coherenceMidMuted : coherenceMid;
  }

  static Color winProbability(double v, {bool muted = false}) {
    if (v > winProbStrongThreshold) {
      return muted ? evalPositiveMuted : evalPositive;
    }
    if (v > winProbMidThreshold) {
      return muted ? const Color(0xFF8FAF92) : const Color(0xFF81C784);
    }
    if (v > winProbNeutralThreshold) {
      return muted ? evalNeutralMuted : evalNeutral;
    }
    return muted ? warningMuted : warning;
  }

  static Color ease(double ease, {bool muted = false}) {
    if (ease > easeHighThreshold) {
      return muted ? evalPositiveMuted : evalPositive;
    }
    if (ease > easeMidThreshold) {
      return muted ? coherenceMidMuted : coherenceMid;
    }
    return muted ? warningMuted : warning;
  }

  static Color cpl(double cpl, {bool muted = false}) {
    if (cpl < cplExcellentThreshold) {
      return muted ? evalPositiveMuted : evalPositive;
    }
    if (cpl < cplGoodThreshold) {
      return muted ? const Color(0xFF8FAF92) : const Color(0xFF81C784);
    }
    if (cpl < cplFairThreshold) {
      return muted ? coherenceMidMuted : coherenceMid;
    }
    return muted ? warningMuted : warning;
  }

  static const warningMuted = Color(0xFF9A8868);
}

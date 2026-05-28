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

  // ── Chess eval (centipawns) ─────────────────────────────────────────────

  static const evalPositive = Color(0xFF66BB6A);
  static const evalNegative = Color(0xFFEF5350);
  static const evalNeutral = Color(0xFFB0B0B0);

  static const evalPositiveMuted = Color(0xFF7A9E82);
  static const evalNegativeMuted = Color(0xFF9E7A7A);
  static const evalNeutralMuted = Color(0xFF8A8A8A);

  static Color cpEval(int cp, {bool muted = false, int threshold = 50}) {
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
      if (cp > 100) return const Color(0xFF2A3530);
      if (cp > 30) return const Color(0xFF252E2A);
      if (cp > -30) return const Color(0xFF2C2C2C);
      if (cp > -100) return const Color(0xFF302825);
      return const Color(0xFF302525);
    }
    if (cp > 100) return const Color(0xFF1B3D1F);
    if (cp > 30) return const Color(0xFF1E3320);
    if (cp > -30) return const Color(0xFF2C2C2C);
    if (cp > -100) return const Color(0xFF3D2525);
    return const Color(0xFF4A2020);
  }

  // ── Analysis sources ────────────────────────────────────────────────────

  static const stockfish = Color(0xFFFFB74D);
  static const expectimax = Color(0xFF4DB6AC);
  static const maia = Color(0xFFCE93D8);
  static const lichessDb = Color(0xFF4DD0E1);
  static const difficulty = Color(0xFFFFCA28);

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

  static const success = Color(0xFF66BB6A);
  static const successSurface = Color(0xFF2E7D32);
  static const danger = Color(0xFFEF5350);
  static const dangerSurface = Color(0xFFC62828);
  static const warning = Color(0xFFFFCA28);
  static const warningSurface = Color(0xFFF57F17);

  static const info = Color(0xFF42A5F5);
  static const infoMuted = Color(0xFF7A8FA8);

  static Color infoColor({bool muted = false}) => muted ? infoMuted : info;

  static const pgnMainLine = Color(0xFF26A69A);
  static const pgnMainLineMuted = Color(0xFF6E8E8A);
  static const pgnEphemeral = Color(0xFF7A8FA8);
  static const pgnEphemeralMuted = Color(0xFF5A6578);

  /// Default SAN in editable PGN panes (soft, readable on dark surfaces).
  static const pgnMove = Color(0xFFB8C8D8);

  /// Move numbers (`1.` / `2...`) — dim, never bold.
  static const pgnMoveNumber = onSurfaceDim;

  /// Current navigation position along the active line.
  static const pgnMoveCurrent = info;
  static const pgnMoveCurrentBg = Color(0xFF1A3348);

  /// Explicitly selected move (comment editing, context menu target).
  static const pgnMoveSelectedBg = Color(0xFF1565C0);

  /// Saved sideline / variation text and brackets.
  static const pgnVariation = pgnMainLineMuted;

  /// On-the-fly analysis moves (distinct from repertoire, not orange).
  static const pgnEphemeralMove = infoMuted;
  static const pgnEphemeralBg = Color(0xFF243040);

  /// Inline move comments.
  static const pgnComment = onSurfaceMuted;

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
    if (c >= 0.7) return muted ? coherenceHighMuted : coherenceHigh;
    if (c >= 0.4) return muted ? coherenceMidMuted : coherenceMid;
    return muted ? coherenceLowMuted : coherenceLow;
  }

  static Color trapScore(double score, {bool muted = false}) {
    if (score >= 0.5) return muted ? danger.withValues(alpha: 0.7) : danger;
    if (score >= 0.2) return muted ? warningMuted : warning;
    return muted ? coherenceMidMuted : coherenceMid;
  }

  static Color winProbability(double v, {bool muted = false}) {
    if (v > 0.65) return muted ? evalPositiveMuted : evalPositive;
    if (v > 0.55) {
      return muted ? const Color(0xFF8FAF92) : const Color(0xFF81C784);
    }
    if (v > 0.45) return muted ? evalNeutralMuted : evalNeutral;
    return muted ? warningMuted : warning;
  }

  static Color ease(double ease, {bool muted = false}) {
    if (ease > 0.8) return muted ? evalPositiveMuted : evalPositive;
    if (ease > 0.6) return muted ? coherenceMidMuted : coherenceMid;
    return muted ? warningMuted : warning;
  }

  static Color cpl(double cpl, {bool muted = false}) {
    if (cpl < 5) return muted ? evalPositiveMuted : evalPositive;
    if (cpl < 15) {
      return muted ? const Color(0xFF8FAF92) : const Color(0xFF81C784);
    }
    if (cpl < 30) return muted ? coherenceMidMuted : coherenceMid;
    return muted ? warningMuted : warning;
  }

  static const warningMuted = Color(0xFF9A8868);
}

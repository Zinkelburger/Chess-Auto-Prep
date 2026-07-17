/// Movetext type scale for PGN viewer / editor surfaces.
///
/// Colors come from [AppColors]; shared scale from [AppTextStyles]. Change
/// appearance here (or the AppColors `pgn*` tokens) — not at call sites.
library;

import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_text_styles.dart';

abstract final class PgnTextStyles {
  static const move = TextStyle(
    fontFamily: 'monospace',
    fontSize: 14,
    height: 1.35,
    color: AppColors.pgnMove,
  );

  static const moveNumber = TextStyle(
    fontFamily: 'monospace',
    fontSize: 14,
    height: 1.35,
    color: AppColors.pgnMoveNumber,
  );

  /// Same ink as [move]; italic + own-row layout distinguish comments.
  static const comment = TextStyle(
    fontSize: 14,
    height: 1.5,
    fontStyle: FontStyle.italic,
    color: AppColors.pgnComment,
  );

  /// Same ink as mainline; parentheses + own-row layout mark sidelines.
  static const variation = TextStyle(
    fontFamily: 'monospace',
    fontSize: 14,
    height: 1.35,
    color: AppColors.pgnVariation,
  );

  /// Root style for a variation row's RichText. Deliberately family-free:
  /// move/bracket spans set monospace themselves, so comment prose (which
  /// sets no family) inherits the proportional default and reads as prose,
  /// not code. Do NOT root variation rows at [variation]/[ephemeral].
  static const variationRoot = TextStyle(
    fontSize: 14,
    height: 1.35,
    color: AppColors.pgnVariation,
  );

  static const ephemeral = TextStyle(
    fontFamily: 'monospace',
    fontSize: 14,
    height: 1.35,
    color: AppColors.pgnEphemeralMove,
  );

  /// Bold "you are here" chip text. Assumes the platform monospace face keeps
  /// equal advance widths at w600 (true of DejaVu/Liberation/SF Mono), so
  /// highlighting a move never reflows wrapped movetext.
  static const currentMove = TextStyle(
    fontFamily: 'monospace',
    fontSize: 14,
    height: 1.35,
    fontWeight: FontWeight.w600,
    color: AppColors.pgnMoveCurrentFg,
  );

  /// Branch-picker chips under the movetext.
  static const branchChip = TextStyle(
    fontFamily: 'monospace',
    fontSize: 15,
    height: 1.2,
    color: AppTextStyles.ink,
  );

  static const branchChipBadge = TextStyle(
    fontFamily: 'monospace',
    fontSize: 12,
    height: 1.1,
    fontWeight: FontWeight.w600,
    color: AppTextStyles.ink,
  );

  // ── Rich comment blocks (Chessable/Forward Chess book formatting) ───────

  static const commentHeader = TextStyle(
    fontSize: 15.5,
    fontWeight: FontWeight.bold,
    height: 1.4,
    color: AppColors.pgnComment,
  );

  static const commentQuote = TextStyle(
    fontSize: 13.5,
    height: 1.5,
    fontStyle: FontStyle.italic,
    color: Color(0xDDF2F2F2),
  );

  static const commentBracket = TextStyle(
    fontSize: 13.5,
    height: 1.4,
    fontStyle: FontStyle.italic,
    color: AppColors.pgnComment,
  );

  static const commentFen = TextStyle(
    fontFamily: 'monospace',
    fontSize: 11.5,
    color: AppColors.pgnComment,
  );

  static const commentLink = TextStyle(
    fontFamily: 'monospace',
    fontSize: 13.5,
    height: 1.5,
    color: AppColors.info,
    decoration: TextDecoration.underline,
    decorationColor: AppColors.info,
  );
}

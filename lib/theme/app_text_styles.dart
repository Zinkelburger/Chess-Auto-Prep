/// Shared text roles for Chess Auto Prep.
///
/// Five roles, one UI face, one mono face. Prefer these (or
/// [ThemeData.textTheme] mapped from them) over ad-hoc
/// `TextStyle(fontSize: …, color: Colors.grey[…])`. Colors come from
/// [AppColors] so ink and type scale stay one place to tune.
///
/// The scale, and the floor: **title 18 · body 14 · secondary 13 · small 12 ·
/// mono 13**. Nothing readable goes below 12 — the app lives on desktop
/// monitors at 1×, where 10–11px text is a smudge. Board coordinates and
/// other on-board glyphs are the one exception and are not text roles.
///
/// Domain packs (e.g. [PgnTextStyles]) may refine size/weight/italic on top
/// of these roles without inventing new base colors.
library;

import 'package:flutter/material.dart';

import 'app_colors.dart';

abstract final class AppTextStyles {
  // ── Faces (bundled in pubspec.yaml; see assets/fonts) ────────────────────

  /// UI text. Inter: drawn for screens at small sizes, with real tabular
  /// figures. Set once on [ThemeData.fontFamily]; every style inherits it.
  static const String uiFamily = 'Inter';

  /// Moves, FENs, evals, anything that has to line up in columns.
  /// `'monospace'` used to be the family here, which fontconfig resolves to
  /// DejaVu on Linux and Windows resolves to nothing reliable.
  static const String monoFamily = 'SourceCodePro';

  /// Digits the same width everywhere, so ratings, evals and counts line up
  /// between rows without a mono face.
  static const List<FontFeature> tabularFigures = [
    FontFeature.tabularFigures(),
  ];

  // ── Ink (aliases of AppColors so PGN + chrome cannot drift) ─────────────

  /// Primary readable body ink on [AppColors.surface].
  static const Color ink = AppColors.ink;

  /// Alias of [ink] — kept for call sites; the second grey was retired.
  static const Color inkSoft = AppColors.inkSoft;

  // ── Roles ───────────────────────────────────────────────────────────────

  static const body = TextStyle(
    fontSize: 14,
    height: 1.4,
    color: ink,
    fontFeatures: tabularFigures,
  );

  static const bodyStrong = TextStyle(
    fontSize: 14,
    height: 1.4,
    fontWeight: FontWeight.w600,
    color: ink,
    fontFeatures: tabularFigures,
  );

  /// Secondary labels / chrome.
  static const muted = TextStyle(
    fontSize: 13,
    height: 1.35,
    color: AppColors.onSurfaceMuted,
    fontFeatures: tabularFigures,
  );

  /// The floor: dense tables and chips only.
  static const caption = TextStyle(
    fontSize: 12,
    height: 1.3,
    color: AppColors.onSurfaceMuted,
    fontFeatures: tabularFigures,
  );

  /// Field hints, helper text, and inline guidance.
  static const hint = TextStyle(
    fontSize: 13,
    height: 1.35,
    color: AppColors.onSurfaceMuted,
  );

  static const title = TextStyle(
    fontSize: 18,
    height: 1.3,
    fontWeight: FontWeight.w600,
    color: ink,
  );

  static const subtitle = TextStyle(
    fontSize: 14,
    height: 1.3,
    fontWeight: FontWeight.w500,
    color: ink,
  );

  /// Uppercase section label inside a pane ("PLAY", "ANALYSIS").
  static const eyebrow = TextStyle(
    fontSize: 12,
    height: 1.2,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.6,
    color: AppColors.onSurfaceMuted,
  );

  static const mono = TextStyle(
    fontFamily: monoFamily,
    fontSize: 13,
    height: 1.35,
    color: ink,
  );

  static const monoDense = TextStyle(
    fontFamily: monoFamily,
    fontSize: 12,
    height: 1.3,
    color: ink,
  );

  /// Empty-state cards: icon uses [AppColors.onSurfaceDim], body must stay AA.
  static const emptyStateTitle = TextStyle(
    fontSize: 16,
    height: 1.3,
    fontWeight: FontWeight.w600,
    color: ink,
  );

  static const emptyStateBody = TextStyle(
    fontSize: 13,
    height: 1.4,
    color: AppColors.onSurfaceMuted,
  );

  /// Maps Material [TextTheme] slots onto these roles so widgets that use
  /// `Theme.of(context).textTheme` stay consistent without a second palette.
  static TextTheme materialTextTheme([TextTheme? base]) {
    final b = base ?? ThemeData.dark().textTheme;
    return b.copyWith(
      displayLarge: b.displayLarge?.copyWith(color: ink),
      displayMedium: b.displayMedium?.copyWith(color: ink),
      displaySmall: b.displaySmall?.copyWith(color: ink),
      headlineLarge: b.headlineLarge?.copyWith(color: ink),
      headlineMedium: b.headlineMedium?.copyWith(color: ink),
      headlineSmall: b.headlineSmall?.copyWith(color: ink),
      bodyLarge: body.copyWith(fontSize: 16),
      bodyMedium: body,
      bodySmall: caption,
      titleLarge: title.copyWith(fontSize: 20),
      titleMedium: title.copyWith(fontSize: 16),
      titleSmall: subtitle,
      labelLarge: bodyStrong,
      labelMedium: caption.copyWith(fontWeight: FontWeight.w500, color: ink),
      labelSmall: caption,
    );
  }
}

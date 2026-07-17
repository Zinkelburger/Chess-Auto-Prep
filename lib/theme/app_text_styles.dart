/// Shared text roles for Chess Auto Prep.
///
/// Prefer these (or [ThemeData.textTheme] mapped from them) over ad-hoc
/// `TextStyle(fontSize: …, color: Colors.grey[…])`. Colors come from
/// [AppColors] so ink and type scale stay one place to tune.
///
/// Domain packs (e.g. [PgnTextStyles]) may refine size/weight/italic on top
/// of these roles without inventing new base colors.
library;

import 'package:flutter/material.dart';

import 'app_colors.dart';

abstract final class AppTextStyles {
  // ── Ink (aliases of AppColors so PGN + chrome cannot drift) ─────────────

  /// Primary readable body ink on [AppColors.surface] (16.7:1).
  static const Color ink = AppColors.ink;

  /// One step softer for hierarchy that must still clear WCAG AA (15.3:1).
  static const Color inkSoft = AppColors.inkSoft;

  // ── Roles ───────────────────────────────────────────────────────────────

  static const body = TextStyle(fontSize: 14, height: 1.4, color: ink);

  static const bodyStrong = TextStyle(
    fontSize: 14,
    height: 1.4,
    fontWeight: FontWeight.w600,
    color: ink,
  );

  /// Secondary labels / chrome — still ≥4.5:1 on surface.
  static const muted = TextStyle(
    fontSize: 13,
    height: 1.35,
    color: AppColors.onSurfaceMuted,
  );

  static const caption = TextStyle(
    fontSize: 12,
    height: 1.3,
    color: AppColors.onSurfaceMuted,
  );

  /// Field hints, helper text, and inline guidance (never grey[600]).
  static const hint = TextStyle(
    fontSize: 12.5,
    height: 1.35,
    color: AppColors.onSurfaceMuted,
  );

  static const title = TextStyle(
    fontSize: 16,
    height: 1.3,
    fontWeight: FontWeight.w600,
    color: ink,
  );

  static const subtitle = TextStyle(
    fontSize: 14,
    height: 1.3,
    fontWeight: FontWeight.w500,
    color: inkSoft,
  );

  static const mono = TextStyle(
    fontFamily: 'monospace',
    fontSize: 14,
    height: 1.35,
    color: ink,
  );

  static const monoDense = TextStyle(
    fontFamily: 'monospace',
    fontSize: 12.5,
    height: 1.3,
    color: ink,
  );

  /// Empty-state cards: icon uses [AppColors.onSurfaceDim], body must stay AA.
  static const emptyStateTitle = TextStyle(
    fontSize: 16,
    height: 1.3,
    fontWeight: FontWeight.w600,
    color: inkSoft,
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
      titleMedium: title,
      titleSmall: subtitle,
      labelLarge: bodyStrong.copyWith(fontSize: 14),
      labelMedium: caption.copyWith(
        fontWeight: FontWeight.w500,
        color: inkSoft,
      ),
      labelSmall: caption.copyWith(fontSize: 11),
    );
  }
}

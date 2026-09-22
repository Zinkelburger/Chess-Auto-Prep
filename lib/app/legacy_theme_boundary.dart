import 'package:flutter/material.dart';
import '../design_system/theme/app_theme.dart';

/// Temporary boundary for panels with fixed dark colors. Remove each call site
/// when its owning workflow retires the legacy_theme_consumers.json entries.
/// This does not change the app preference or the surrounding migrated chrome.
class LegacyThemeBoundary extends StatelessWidget {
  const LegacyThemeBoundary({super.key, required this.child});
  final Widget child;
  static final _theme = AppTheme.dark();
  @override
  Widget build(BuildContext context) => Theme(
    data: _theme,
    child: Material(color: _theme.scaffoldBackgroundColor, child: child),
  );
}

/// Legacy planning/audit pages still have fixed dark controls. Their owner
/// keeps the migrated workspace toolbar outside this temporary route boundary.
class LegacyPageRoute<T> extends MaterialPageRoute<T> {
  LegacyPageRoute({required WidgetBuilder builder, super.fullscreenDialog})
    : super(
        builder: (_) => LegacyThemeBoundary(child: Builder(builder: builder)),
      );
}

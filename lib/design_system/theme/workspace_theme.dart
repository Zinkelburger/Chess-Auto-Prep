import 'package:flutter/material.dart';

/// Workspace-specific surfaces, resolved from the active app theme. Standard
/// foreground, outline and status roles continue to belong to ColorScheme.
@immutable
class WorkspaceTheme extends ThemeExtension<WorkspaceTheme> {
  const WorkspaceTheme({
    required this.canvas,
    required this.panel,
    required this.inset,
  });
  final Color canvas;
  final Color panel;
  final Color inset;

  factory WorkspaceTheme.fromScheme(ColorScheme colors) => WorkspaceTheme(
    canvas: colors.surface,
    panel: colors.surfaceContainerLow,
    inset: colors.surfaceContainerHigh,
  );

  static WorkspaceTheme of(BuildContext context) {
    final theme = Theme.of(context);
    // Shared controls also work in plain Material hosts. Both production app
    // themes and the catalog explicitly register the extension.
    return theme.extension<WorkspaceTheme>() ??
        WorkspaceTheme.fromScheme(theme.colorScheme);
  }

  @override
  WorkspaceTheme copyWith({Color? canvas, Color? panel, Color? inset}) =>
      WorkspaceTheme(
        canvas: canvas ?? this.canvas,
        panel: panel ?? this.panel,
        inset: inset ?? this.inset,
      );

  @override
  WorkspaceTheme lerp(covariant WorkspaceTheme? other, double t) {
    if (other == null) return this;
    return WorkspaceTheme(
      canvas: Color.lerp(canvas, other.canvas, t)!,
      panel: Color.lerp(panel, other.panel, t)!,
      inset: Color.lerp(inset, other.inset, t)!,
    );
  }
}

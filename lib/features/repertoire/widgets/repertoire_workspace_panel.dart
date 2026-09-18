import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';

/// Quiet, consistent chrome for the notation and reference surfaces.
class RepertoireWorkspacePanel extends StatelessWidget {
  const RepertoireWorkspacePanel({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(8),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        border: Border.all(color: AppColors.divider),
        borderRadius: BorderRadius.circular(8),
      ),
      child: child,
    ),
  );
}

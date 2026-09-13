import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';

/// Quiet, consistent chrome for the notation and reference surfaces.
class RepertoireWorkspacePanel extends StatelessWidget {
  const RepertoireWorkspacePanel({
    super.key,
    this.title,
    required this.icon,
    required this.child,
    this.actions = const [],
  });
  final String? title;
  final IconData icon;
  final Widget child;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(8),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        border: Border.all(color: AppColors.divider),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          if (title != null)
            Container(
              height: 34,
              padding: const EdgeInsets.only(left: 12, right: 4),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: AppColors.divider)),
              ),
              child: Row(
                children: [
                  Icon(icon, size: 16, color: AppColors.onSurfaceMuted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title!,
                      style: AppTextStyles.muted.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  ...actions,
                ],
              ),
            ),
          Expanded(child: child),
        ],
      ),
    ),
  );
}

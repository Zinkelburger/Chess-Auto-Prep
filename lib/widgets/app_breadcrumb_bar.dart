import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/app_history.dart';
import '../core/app_state.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';

/// The app-wide breadcrumb strip mounted once above the mode `IndexedStack`:
/// a back arrow plus the [AppHistory] trail as clickable crumbs. Always
/// visible (static layout) so navigation never shifts the screens below it.
class AppBreadcrumbBar extends StatelessWidget {
  const AppBreadcrumbBar({super.key});

  @override
  Widget build(BuildContext context) {
    final history = context.watch<AppHistory>();
    // Mode switching is locked during generation (same rule as the mode
    // menu); crumbs are navigation, so they lock too.
    final locked = context.select<AppState, bool>(
      (s) => s.isRepertoireGenerating,
    );
    final entries = history.entries;

    return Material(
      color: AppColors.surfaceElevated,
      child: Container(
        height: 34,
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: AppColors.divider)),
        ),
        child: Row(
          children: [
            IconButton(
              onPressed: history.canGoBack && !locked ? history.back : null,
              icon: const Icon(Icons.arrow_back, size: 18),
              tooltip: locked
                  ? 'Locked — repertoire generation in progress'
                  : 'Back to previous screen',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 34),
              padding: EdgeInsets.zero,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                // Newest crumb stays visible when the trail overflows.
                reverse: true,
                child: Row(
                  children: [
                    for (var i = 0; i < entries.length; i++) ...[
                      if (i > 0)
                        const Icon(
                          Icons.chevron_right,
                          size: 16,
                          color: AppColors.onSurfaceDim,
                        ),
                      _Crumb(
                        label: entries[i].label,
                        isCurrent: i == entries.length - 1,
                        onTap: i == entries.length - 1 || locked
                            ? null
                            : () => history.popTo(i),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Crumb extends StatelessWidget {
  const _Crumb({required this.label, required this.isCurrent, this.onTap});

  final String label;
  final bool isCurrent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final style = isCurrent
        ? AppTextStyles.body.copyWith(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: AppColors.ink,
          )
        : AppTextStyles.body.copyWith(
            fontSize: 13,
            color: AppColors.onSurfaceSoft,
          );
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Text(label, style: style, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}

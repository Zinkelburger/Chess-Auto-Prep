import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/app_history.dart';
import '../core/app_state.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';

/// A screen's app-bar title with the [AppHistory] trail beside it —
/// `PGN Viewer   Tactics ▸ Game 12 vs foo` — instead of on a strip of its own
/// above the bar. A second full-width bar for two words of navigation state
/// was pure chrome; the app bar already has the room.
///
/// The trail is strictly secondary, so it is dropped rather than allowed to
/// squeeze the title: it appears only when there is a trail to show *and* the
/// bar is wide enough that splitting it leaves the title workable. Below that
/// the title renders exactly as it did before this widget existed.
class AppBarTitleWithTrail extends StatelessWidget {
  const AppBarTitleWithTrail({super.key, required this.title});

  final Widget title;

  /// Bar width under which the trail is not worth the room it costs. Picked
  /// so the title keeps ~300px — enough for a repertoire switcher plus its
  /// dropdown arrow, which is what overflowed when the split was
  /// unconditional.
  static const double minWidthForTrail = 520;

  @override
  Widget build(BuildContext context) {
    // Nullable lookup: screens are also mounted standalone in widget tests
    // and pushed routes, where no AppHistory is in scope.
    final history = context.watch<AppHistory?>();
    if (history == null || history.entries.length < 2) return title;

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < minWidthForTrail) return title;
        return Row(
          children: [
            Flexible(flex: 3, child: title),
            const Flexible(flex: 2, child: AppBreadcrumbTrail()),
          ],
        );
      },
    );
  }
}

/// The crumbs themselves. Scrolls horizontally rather than overflowing, so it
/// is safe at any width its parent hands it.
class AppBreadcrumbTrail extends StatelessWidget {
  const AppBreadcrumbTrail({super.key});

  @override
  Widget build(BuildContext context) {
    final history = context.watch<AppHistory?>();
    final entries = history?.entries ?? const <AppHistoryEntry>[];
    // A lone root crumb only repeats the app-bar title sitting next to it.
    if (history == null || entries.length < 2) return const SizedBox.shrink();

    // Mode switching is locked during generation (same rule as the mode
    // menu); crumbs are navigation, so they lock too.
    final locked = context.select<AppState?, bool>(
      (s) => s?.isRepertoireGenerating ?? false,
    );

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      // Newest crumb stays visible when the trail overflows.
      reverse: true,
      child: Row(
        children: [
          const SizedBox(width: 16),
          for (var i = 0; i < entries.length; i++) ...[
            if (i > 0)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 1),
                child: Icon(
                  Icons.chevron_right,
                  size: 17,
                  color: AppColors.onSurfaceSoft,
                ),
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
    // A step below the app-bar title, not two: the title names the screen and
    // the trail is secondary, but "secondary" was being read as "grey mush" —
    // where you are is the one thing on the bar you have to be able to read at
    // a glance. The current crumb gets full ink; earlier ones are the soft
    // step, which is where the hierarchy now lives.
    final style = AppTextStyles.body.copyWith(
      fontSize: 14,
      fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w400,
      color: isCurrent ? AppColors.ink : AppColors.onSurfaceSoft,
    );
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
        child: Text(label, style: style, maxLines: 1),
      ),
    );
  }
}

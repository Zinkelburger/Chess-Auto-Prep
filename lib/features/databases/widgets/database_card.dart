/// One store on the Databases page, in the shape every store uses.
///
/// The four database surfaces this page replaced each answered a different
/// subset of the same questions, in a different order, with a different noun
/// for the thing being described — "dump", "store", "database", "evaluations".
/// A reader could not compare two of them without re-reading both. So the
/// card is a fixed form and every row fills the same five slots:
///
///   1. **What it is** — one behaviour-first line. Never the file format.
///   2. **What is on disk** — a count and a size, or "Not set up".
///   3. **How fresh** — when it was last checked, where checking is a thing.
///   4. **What it buys you** — which parts of the app get better. This is the
///      slot the old panels had nowhere to put, so the answer lived in a
///      section subtitle shared by two unrelated stores.
///   5. **One primary action**, with the rest behind ⋮.
///
/// A slot with nothing to say is omitted, never filled with a placeholder.
///
/// The rule this card exists to enforce is [DatabaseAction.disabledReason]:
/// a greyed-out button must say why at the button. The page it replaced had a
/// disabled "Download database…" whose explanation was a warning banner three
/// controls further up, and nothing tied the two together.
library;

import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../widgets/app_overflow_menu.dart';

/// How much of a card is offered to the reader.
enum DatabaseAvailability {
  /// Set up and in use. Its size is real.
  ready,

  /// Could be set up on this machine, and is not.
  notSetUp,

  /// Cannot be set up in this build or on this platform. The card still
  /// appears — a store you cannot have is worth knowing about — but it is
  /// collapsed, muted, and offers nothing to press.
  unavailable,
}

/// A button on a card, with the reason it is off attached to it.
class DatabaseAction {
  const DatabaseAction({
    required this.label,
    required this.onRun,
    this.icon,
    this.disabledReason,
  });

  final String label;
  final VoidCallback onRun;
  final IconData? icon;

  /// Non-null greys the button out and explains itself in a tooltip.
  final String? disabledReason;

  bool get enabled => disabledReason == null;
}

class DatabaseCard extends StatelessWidget {
  const DatabaseCard({
    super.key,
    required this.title,
    required this.icon,
    required this.whatItIs,
    required this.whatItBuys,
    required this.availability,
    this.status,
    this.statusDetail,
    this.freshness,
    this.primary,
    this.secondary,
    this.menu = const [],
    this.body,
    this.details,
    this.detailsLabel = 'Settings',
    this.unavailableReason,
    this.recommended = false,
  });

  final String title;
  final IconData icon;

  /// One line, behaviour first. What the store *does for you*.
  final String whatItIs;

  /// Which parts of the app get better when this exists.
  final String whatItBuys;

  final DatabaseAvailability availability;

  /// The headline figure — "1,920,172 games · 2.1 GB". Null shows the
  /// availability's own words instead.
  final String? status;

  /// A second line under [status] for anything that qualifies it.
  final String? statusDetail;

  /// "Checked 3 h ago", already formatted. Omitted where checking is not a
  /// thing this store does.
  final String? freshness;

  final DatabaseAction? primary;
  final DatabaseAction? secondary;
  final List<AppMenuEntry> menu;

  /// Always-visible content under the actions — a progress bar, a warning.
  final Widget? body;

  /// The knobs, behind a disclosure. Settings that only matter once you have
  /// the store are not worth the height they cost before you do.
  final Widget? details;
  final String detailsLabel;

  /// Why this card is [DatabaseAvailability.unavailable], in the user's terms.
  /// Never a shell command: a packaged install has no checkout to run one in.
  final String? unavailableReason;

  /// Marks the one option a reader should take when two cards do the same job
  /// at wildly different cost.
  final bool recommended;

  @override
  Widget build(BuildContext context) {
    final unavailable = availability == DatabaseAvailability.unavailable;
    // A [Material], not a decorated [Container]: the card holds an
    // [ExpansionTile], and a ListTile paints its background and ink on the
    // nearest Material ancestor. A DecoratedBox in between hides both, which
    // Flutter reports on every build — six times per frame on this page.
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: AppColors.surfaceContainer,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(
            color: recommended ? AppColors.accent : AppColors.divider,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(unavailable),
              const SizedBox(height: 6),
              Text(
                whatItIs,
                style: unavailable
                    ? AppTextStyles.muted
                    : AppTextStyles.caption,
              ),
              if (!unavailable) ...[
                const SizedBox(height: 2),
                Text(whatItBuys, style: AppTextStyles.muted),
              ],
              if (unavailable && unavailableReason != null) ...[
                const SizedBox(height: 8),
                _reasonBanner(unavailableReason!),
              ],
              if (!unavailable) ...[
                if (body != null) ...[const SizedBox(height: 10), body!],
                if (primary != null || secondary != null) ...[
                  const SizedBox(height: 10),
                  _actions(),
                ],
                if (details != null) ...[
                  const SizedBox(height: 4),
                  _detailsTile(context),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(bool unavailable) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          icon,
          size: 18,
          color: unavailable ? AppColors.onSurfaceDisabled : AppColors.ink,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Row(
            children: [
              Flexible(
                child: Text(
                  title,
                  style: unavailable
                      ? AppTextStyles.muted.copyWith(
                          fontWeight: FontWeight.w600,
                        )
                      : AppTextStyles.bodyStrong,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (recommended) ...[
                const SizedBox(width: 8),
                const _Badge(text: 'START HERE', color: AppColors.accent),
              ],
            ],
          ),
        ),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              status ?? _defaultStatus,
              style: switch (availability) {
                DatabaseAvailability.ready => AppTextStyles.bodyStrong,
                _ => AppTextStyles.muted,
              },
            ),
            if (statusDetail != null)
              Text(statusDetail!, style: AppTextStyles.caption),
            if (freshness != null)
              Text(freshness!, style: AppTextStyles.caption),
          ],
        ),
        if (menu.isNotEmpty && !unavailable) ...[
          const SizedBox(width: 4),
          AppOverflowMenu(entries: menu),
        ],
      ],
    );
  }

  String get _defaultStatus => switch (availability) {
    DatabaseAvailability.ready => 'Ready',
    DatabaseAvailability.notSetUp => 'Not set up',
    DatabaseAvailability.unavailable => 'Unavailable',
  };

  Widget _actions() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (primary != null) _button(primary!, filled: true),
        if (secondary != null) _button(secondary!, filled: false),
      ],
    );
  }

  /// A disabled button is wrapped rather than left bare: [Tooltip] does not
  /// fire on a disabled child, so the reason has to hang on something that is
  /// still hit-testable.
  Widget _button(DatabaseAction action, {required bool filled}) {
    final child = filled
        ? FilledButton.icon(
            onPressed: action.enabled ? action.onRun : null,
            icon: Icon(action.icon ?? Icons.play_arrow, size: 16),
            label: Text(action.label),
          )
        : OutlinedButton.icon(
            onPressed: action.enabled ? action.onRun : null,
            icon: Icon(action.icon ?? Icons.tune, size: 16),
            label: Text(action.label),
          );
    if (action.enabled) return child;
    return Tooltip(
      message: action.disabledReason!,
      child: MouseRegion(
        cursor: SystemMouseCursors.basic,
        child: AbsorbPointer(child: child),
      ),
    );
  }

  /// The disclosure, built against the *app's* theme with one field changed.
  ///
  /// It briefly used `ThemeData.dark()` here, which is a whole second theme
  /// rather than an override: the tile then drew its ink and its background
  /// from colours the card knows nothing about, and Flutter said so on every
  /// build ("ListTile background color or ink splashes may be invisible").
  /// The only thing this needs to change is the divider the tile draws for
  /// itself, which doubles up with the card's own border.
  Widget _detailsTile(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(top: 4, bottom: 8),
        title: Text(detailsLabel, style: AppTextStyles.caption),
        children: [details!],
      ),
    );
  }

  Widget _reasonBanner(String message) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.30)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.info_outline,
            size: 16,
            color: AppColors.warningMuted,
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(message, style: AppTextStyles.caption)),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(text, style: AppTextStyles.eyebrow.copyWith(color: color)),
    );
  }
}

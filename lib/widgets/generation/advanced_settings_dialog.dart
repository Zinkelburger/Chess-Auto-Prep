import 'dart:async';

import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';

/// One entry in [AdvancedSettingsDialog]: a title, the icon it is listed
/// under, and the builder for its controls.
///
/// [build] is handed a `refresh` callback rather than reaching for a state
/// object, which is what lets the section builders live in the form while the
/// dialog that arranges them lives here.
class AdvancedSection {
  AdvancedSection(this.title, this.icon, this.build, {this.unavailable});

  final String title;
  final IconData icon;
  final List<Widget> Function(VoidCallback refresh) build;

  /// Why none of this section's knobs can apply right now, or null when they
  /// can.
  ///
  /// A section every one of whose fields would be greyed out is noise: the
  /// reader still has to scan five dead controls to learn the section is not
  /// for them. Returning a reason here shows that one sentence instead, so
  /// the section stays discoverable — and stays in the table of contents —
  /// without spending screen space on knobs that cannot be touched.
  ///
  /// Evaluated on every dialog build, so it tracks changes made in the
  /// dialog itself.
  final String? Function()? unavailable;

  /// Scroll anchor, shared between this section's card and its table-of-
  /// contents entry. Held by the section rather than the dialog so the two
  /// cannot disagree about which card a jump link points at.
  final GlobalKey anchor = GlobalKey();
}

/// The advanced gear dialog: every remaining generation knob, grouped into
/// titled cards with a table of contents down the left so nothing has to be
/// hunted for.
///
/// Deliberately knows nothing about [TreeBuildConfig] or the form's state.
/// It arranges whatever sections it is given, which is what makes it
/// testable on its own — the form is a 2,300-line class across seven part
/// files, and this chrome was 210 of those lines with no way to exercise it
/// short of driving the whole form.
class AdvancedSettingsDialog extends StatefulWidget {
  const AdvancedSettingsDialog({super.key, required this.sections});

  final List<AdvancedSection> sections;

  /// Opens the dialog and completes when it closes.
  static Future<void> show(
    BuildContext context, {
    required List<AdvancedSection> sections,
  }) => showDialog<void>(
    context: context,
    builder: (_) => AdvancedSettingsDialog(sections: sections),
  );

  @override
  State<AdvancedSettingsDialog> createState() => _AdvancedSettingsDialogState();
}

class _AdvancedSettingsDialogState extends State<AdvancedSettingsDialog> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// Every section's controls read the form's live state, so a change in one
  /// card can enable or disable a field in another. Rebuilding the whole
  /// dialog is the only way to keep those in step.
  void _refresh() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 860;
    return Dialog(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: wide ? 880 : 660,
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _header(context),
            const Divider(height: 1),
            Flexible(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (wide) ...[
                    _TableOfContents(sections: widget.sections),
                    const VerticalDivider(width: 1),
                  ],
                  Expanded(
                    // Not a ListView: every card must stay mounted so the
                    // TOC's Scrollable.ensureVisible can reach any anchor,
                    // on or off screen.
                    child: SingleChildScrollView(
                      controller: _scrollController,
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final section in widget.sections)
                            _SectionCard(section: section, refresh: _refresh),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 12, 8, 8),
    child: Row(
      children: [
        Text(
          'Advanced generation settings',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            'Everything on the main form stays in sync with these.',
            style: AppTextStyles.caption.copyWith(fontSize: 12),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Close',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    ),
  );
}

/// Jump links down the left edge of the dialog.
class _TableOfContents extends StatelessWidget {
  const _TableOfContents({required this.sections});

  final List<AdvancedSection> sections;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      // Fits the longest section name beside its icon; at 190 the two
      // longest ellipsised to 'Coverage & line ...' / 'Explanatory vari...'.
      width: 215,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'SECTIONS',
              style: AppTextStyles.caption.copyWith(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
            ),
          ),
          for (final section in sections)
            ListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              leading: Icon(section.icon, size: 18),
              title: Text(
                section.title,
                style: const TextStyle(fontSize: 12),
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () {
                final target = section.anchor.currentContext;
                if (target == null) return;
                unawaited(
                  Scrollable.ensureVisible(
                    target,
                    duration: const Duration(milliseconds: 220),
                    alignment: 0.02,
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

/// One bordered, titled block. The rule + heading is what makes the dialog
/// scannable instead of one long column of fields.
class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.section, required this.refresh});

  final AdvancedSection section;
  final VoidCallback refresh;

  @override
  Widget build(BuildContext context) {
    final reason = section.unavailable?.call();
    return Container(
      key: section.anchor,
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.outline),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: const BoxDecoration(
              color: AppColors.surfaceContainer,
              borderRadius: BorderRadius.vertical(top: Radius.circular(9)),
            ),
            child: Row(
              children: [
                Icon(section.icon, size: 16, color: AppColors.onSurfaceSoft),
                const SizedBox(width: 8),
                Text(
                  section.title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: reason != null
                  ? [
                      Text(
                        reason,
                        style: AppTextStyles.caption.copyWith(fontSize: 12),
                      ),
                    ]
                  : section.build(refresh),
            ),
          ),
        ],
      ),
    );
  }
}

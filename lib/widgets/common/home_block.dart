/// One block of the tactics home column: an uppercase heading, an optional
/// trailing control, and the block's content. The column is five of these
/// (Play, Analysis, Openings, Accounts, Books); sharing the frame keeps their
/// edges, headings and padding identical, and [labelWidth] keeps the label
/// columns of the fact blocks aligned with each other.
library;

import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';

class HomeBlock extends StatelessWidget {
  const HomeBlock({
    super.key,
    required this.heading,
    required this.children,
    this.trailing,
  });

  /// Width of the label column in a block that lists facts as `label value`
  /// rows (the site in Accounts, the colour in Books). One number, so rows in
  /// neighbouring blocks line up.
  static const double labelWidth = 96;

  final String heading;
  final Widget? trailing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 28,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    heading.toUpperCase(),
                    style: AppTextStyles.eyebrow,
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
          const SizedBox(height: 4),
          ...children,
        ],
      ),
    );
  }
}

/// The "Change…" control on a block whose content is a statement of settings
/// (Accounts, Books): the same compact text button as Play's "Filters…", so
/// every block's one action sits in the same place at the same weight.
class HomeBlockAction extends StatelessWidget {
  const HomeBlockAction({
    super.key,
    required this.label,
    required this.onPressed,
    this.buttonKey,
  });

  final String label;
  final VoidCallback onPressed;
  final Key? buttonKey;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      key: buttonKey,
      onPressed: onPressed,
      style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
      child: Text(label),
    );
  }
}

/// One `label value` row inside a fact block. The label sits in the shared
/// [HomeBlock.labelWidth] column in body ink; the value is whatever the
/// caller passes, top-aligned so a two-line value keeps its label on the
/// first line.
class HomeBlockRow extends StatelessWidget {
  const HomeBlockRow({super.key, required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: HomeBlock.labelWidth,
            child: Text(label, style: AppTextStyles.body),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

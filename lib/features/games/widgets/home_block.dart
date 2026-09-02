/// One block of the tactics home column: an uppercase heading, an optional
/// trailing control, and the block's content. The column is three of these
/// (Play, Analysis, Openings) over a footer; sharing the frame keeps their
/// edges, headings and padding identical.
library;

import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';

class HomeBlock extends StatelessWidget {
  const HomeBlock({
    super.key,
    required this.heading,
    required this.children,
    this.trailing,
  });

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

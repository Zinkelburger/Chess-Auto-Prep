/// Responsive two-pane layout shared across screens.
///
/// Renders [primary] and [secondary] side-by-side in a Row when the available
/// width meets [breakpoint], and stacks them in a Column otherwise.
library;

import 'package:flutter/material.dart';
import '../../constants/ui_breakpoints.dart';
import '../../theme/app_colors.dart';

class ResponsiveSplitLayout extends StatelessWidget {
  final Widget primary;
  final Widget secondary;
  final double breakpoint;

  /// Flex ratio for wide layout: primary / secondary.  Defaults to 5:5.
  final int primaryFlex;
  final int secondaryFlex;

  const ResponsiveSplitLayout({
    super.key,
    required this.primary,
    required this.secondary,
    this.breakpoint = kCompactBreakpoint,
    this.primaryFlex = 5,
    this.secondaryFlex = 5,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= breakpoint) {
          return Row(
            children: [
              Expanded(flex: primaryFlex, child: primary),
              Container(width: 1, color: AppColors.outline),
              Expanded(flex: secondaryFlex, child: secondary),
            ],
          );
        }
        return Column(
          children: [
            Expanded(flex: 4, child: primary),
            const Divider(height: 1),
            Expanded(flex: 6, child: secondary),
          ],
        );
      },
    );
  }
}

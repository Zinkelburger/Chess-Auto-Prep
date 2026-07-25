/// Small hoverable ⓘ that explains the control it sits next to.
///
/// Use it wherever a label alone can't carry what an action actually does —
/// the alternative is either a cryptic label or a paragraph of chrome. The
/// pattern was already open-coded in several panels (eval sources, generation
/// form, trap summary); this is the shared version.
library;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

class InfoHint extends StatelessWidget {
  const InfoHint(this.message, {super.key, this.size = 16});

  /// Explanation shown on hover. Keep it to a sentence or three; use `\n`
  /// for line breaks rather than letting one long line wrap raggedly.
  final String message;

  final double size;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: message,
      // Shows quickly (this is the thing the user is already reaching for)
      // but not instantly, so it doesn't flash while the pointer travels.
      waitDuration: const Duration(milliseconds: 250),
      margin: const EdgeInsets.symmetric(horizontal: 24),
      child: Icon(
        Icons.info_outline,
        size: size,
        color: AppColors.onSurfaceMuted,
      ),
    );
  }
}

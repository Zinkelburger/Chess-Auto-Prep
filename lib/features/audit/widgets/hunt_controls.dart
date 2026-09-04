/// The small controls the audit and the two hunts share.
///
/// The audit config panel, the hole-hunt dialog and the trick-hunt dialog are
/// three surfaces onto the same idea — a grid of numeric thresholds with a
/// collapsed "more" section — and each had grown its own copy of the pieces.
/// The copies were close enough that the differences read as accidents rather
/// than decisions: one number field allowed decimals, one disabled itself
/// while a run was in flight, and the disclosure header was byte-identical
/// three times over.
///
/// The visible-cap field is here for the same reason: the audit status row
/// and the hunt report panel both spell out the same forty lines of
/// [InputDecoration], and a comment in one of them used to point at the other
/// and say "same recipe".
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';

/// A labelled numeric threshold, 220px wide, with the explanation on hover.
///
/// The tooltip is where these panels put the "what does this actually do"
/// text — there is no room for helper text under twelve fields in a wrap.
class HuntNumberField extends StatelessWidget {
  const HuntNumberField({
    super.key,
    required this.controller,
    required this.label,
    this.tooltip,
    this.enabled = true,
    this.allowDecimal = false,
  });

  final TextEditingController controller;
  final String label;
  final String? tooltip;

  /// False while a run is in flight, so the settings cannot change under it.
  final bool enabled;

  /// Centipawn thresholds are whole numbers; a couple of audit knobs
  /// (probabilities, multipliers) are not.
  final bool allowDecimal;

  @override
  Widget build(BuildContext context) {
    final field = SizedBox(
      width: 220,
      child: TextField(
        controller: controller,
        enabled: enabled,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        keyboardType: allowDecimal
            ? const TextInputType.numberWithOptions(decimal: true)
            : TextInputType.number,
      ),
    );
    return tooltip == null ? field : Tooltip(message: tooltip!, child: field);
  }
}

/// The tap target that reveals a collapsed section of extra settings.
///
/// Just the header: the caller owns the `if (expanded)` body, because what
/// goes in it is the only part that differs.
class DisclosureHeader extends StatelessWidget {
  const DisclosureHeader({
    super.key,
    required this.label,
    required this.expanded,
    required this.onToggle,
  });

  final String label;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onToggle,
      child: Row(
        children: [
          Icon(
            expanded ? Icons.expand_less : Icons.expand_more,
            size: 16,
            color: AppColors.onSurfaceMuted,
          ),
          const SizedBox(width: 4),
          Text(label, style: AppTextStyles.caption),
        ],
      ),
    );
  }
}

/// The tiny "show the top N" editor that sits in a findings status row.
///
/// Digits only, applied on submit and on tap-outside rather than per
/// keystroke — retyping "10" as "1" then "15" must not re-rank the list twice
/// on the way. Clamping is the caller's, since only it knows the ceiling.
class VisibleCapField extends StatelessWidget {
  const VisibleCapField({
    super.key,
    required this.controller,
    required this.onApply,
  });

  final TextEditingController controller;
  final VoidCallback onApply;

  static const _radius = 4.0;

  static OutlineInputBorder _border(Color color, double width) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(_radius),
        borderSide: BorderSide(color: color, width: width),
      );

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      style: AppTextStyles.caption,
      textAlign: TextAlign.center,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        border: _border(AppColors.outline, 0.5),
        enabledBorder: _border(AppColors.outline, 0.5),
        focusedBorder: _border(AppColors.onSurfaceMuted, 1),
      ),
      onSubmitted: (_) => onApply(),
      onTapOutside: (_) {
        onApply();
        FocusScope.of(context).unfocus();
      },
    );
  }
}

/// A compact popup-menu entry, at the 12px the findings menus use.
///
/// Deliberately *not* [AppTextStyles.caption]: a menu item takes its ink from
/// the menu theme, and pinning the muted grey here would make every entry
/// look disabled. Only the size is ours.
PopupMenuItem<T> compactMenuItem<T>(T value, String label) => PopupMenuItem<T>(
  value: value,
  child: Text(label, style: const TextStyle(fontSize: 12)),
);

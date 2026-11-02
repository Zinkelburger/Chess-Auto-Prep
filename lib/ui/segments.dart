import 'package:flutter/material.dart';

import 'theme.dart';

/// A few answers side by side, one chosen: `Read | Edit`, `White | Black`.
///
/// One look for every segmented choice in the app: compact, no tick on the
/// chosen one (the fill says it), so a segment never grows when it is
/// picked and the row beside it never moves.
class Segments<T> extends StatelessWidget {
  const Segments({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
    this.emptyAllowed = false,
    this.narrow = false,
  });

  final List<ButtonSegment<T>> segments;

  /// The chosen answer. A value no segment has, such as null where null
  /// is not one of the answers, is none chosen, for [emptyAllowed].
  final T? selected;

  /// Null shows the choice but does not let it change.
  final ValueChanged<T>? onChanged;

  /// Whether picking the chosen answer again unchooses it. [onChanged] is
  /// not called then: what is chosen is read from [selected].
  final bool emptyAllowed;

  /// Tighter padding, for a column that has little room.
  final bool narrow;

  static const _style = ButtonStyle(
    animationDuration: Duration.zero,
    visualDensity: VisualDensity.compact,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: Space.s)),
  );

  static const _narrow = ButtonStyle(
    animationDuration: Duration.zero,
    visualDensity: VisualDensity.compact,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: Space.xs)),
  );

  @override
  Widget build(BuildContext context) => SegmentedButton<T>(
    segments: segments,
    selected: {
      for (final segment in segments)
        if (segment.value == selected) segment.value,
    },
    emptySelectionAllowed: emptyAllowed,
    showSelectedIcon: false,
    style: narrow ? _narrow : _style,
    onSelectionChanged: switch (onChanged) {
      final changed? => (picked) {
        if (picked.isNotEmpty) changed(picked.single);
      },
      null => null,
    },
  );
}

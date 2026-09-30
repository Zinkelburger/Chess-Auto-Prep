import 'package:flutter/material.dart';

import 'theme.dart';

/// The engine's on/off switch, drawn small and quiet: a switch scaled to
/// the height of a line of small text, its track only tinted when on, and
/// no halo under the pointer.
class EngineSwitch extends StatelessWidget {
  const EngineSwitch({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: engineSwitchHeight,
      child: FittedBox(
        child: Switch(
          value: value,
          onChanged: onChanged,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          thumbColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? scheme.primary
                : scheme.onSurfaceVariant,
          ),
          trackColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? scheme.primary.withValues(alpha: 0.25)
                : Colors.transparent,
          ),
          trackOutlineColor: WidgetStatePropertyAll(scheme.outline),
        ),
      ),
    );
  }
}

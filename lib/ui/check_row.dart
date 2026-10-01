import 'package:flutter/material.dart';

/// A tick box and what it turns on, on one line, the whole line clickable.
class CheckRow extends StatelessWidget {
  const CheckRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.tooltip,
  });

  final String label;
  final bool value;

  /// Null while the choice cannot change.
  final ValueChanged<bool>? onChanged;

  /// What the setting does, when its name does not say.
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final change = onChanged;
    final row = InkWell(
      onTap: change == null ? null : () => change(!value),
      child: Row(
        children: [
          Checkbox(
            value: value,
            onChanged: change == null ? null : (on) => change(on ?? false),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          Flexible(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
    return tooltip == null ? row : Tooltip(message: tooltip, child: row);
  }
}

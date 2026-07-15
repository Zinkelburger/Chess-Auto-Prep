/// Shared "Games since `<date>`" picker, used by the tactics importer and the
/// repertoire build-from-games form so both present the same date UI.
library;

import 'package:flutter/material.dart';

/// A tappable field that opens a date picker for a "since this date" filter.
///
/// [date] is the current value (null = nothing chosen yet). [onChanged] fires
/// with the picked date, or with null when the clear button is pressed.
class SinceDatePicker extends StatelessWidget {
  const SinceDatePicker({
    super.key,
    required this.date,
    required this.onChanged,
    this.enabled = true,
    this.label = 'Games since',
  });

  final DateTime? date;
  final ValueChanged<DateTime?> onChanged;
  final bool enabled;
  final String label;

  @override
  Widget build(BuildContext context) {
    final displayDate =
        date ?? DateTime.now().subtract(const Duration(days: 7));
    return Row(
      children: [
        Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: enabled ? () => _pickDate(context, displayDate) : null,
            child: InputDecorator(
              decoration: InputDecoration(
                labelText: label,
                border: const OutlineInputBorder(),
                isDense: true,
                enabled: enabled,
                suffixIcon: const Icon(Icons.calendar_today, size: 18),
              ),
              child: Text(
                date != null ? formatDate(date!) : 'Tap to select date',
                style: TextStyle(
                  fontSize: 14,
                  color: date != null ? null : Colors.grey[500],
                ),
              ),
            ),
          ),
        ),
        if (date != null && enabled) ...[
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.clear, size: 18),
            tooltip: 'Clear date',
            onPressed: () => onChanged(null),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ],
    );
  }

  Future<void> _pickDate(BuildContext context, DateTime initial) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2010),
      lastDate: DateTime.now(),
    );
    if (picked != null) onChanged(picked);
  }

  static String formatDate(DateTime d) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }
}

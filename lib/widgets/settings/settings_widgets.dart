/// Shared building blocks for settings surfaces.
///
/// Used by both [SettingsScreen] (global) and the analysis settings sheet
/// (PGN-tab contextual dialog) to avoid duplicated private helpers.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_colors.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// Section header with icon, title, optional subtitle
// ═══════════════════════════════════════════════════════════════════════════════

class SettingsSection extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget child;
  final bool showDivider;

  const SettingsSection({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    required this.child,
    this.showDivider = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(icon, size: 17, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(
            subtitle!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.3,
            ),
          ),
        ],
        const SizedBox(height: 10),
        child,
        if (showDivider) ...[
          const SizedBox(height: 16),
          const Divider(height: 1, color: AppColors.divider),
          const SizedBox(height: 16),
        ],
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Card group (for the full-page SettingsScreen)
// ═══════════════════════════════════════════════════════════════════════════════

class SettingsGroup extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<Widget> children;

  const SettingsGroup({
    super.key,
    required this.title,
    required this.icon,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8, top: 16),
          child: Row(
            children: [
              Icon(icon, size: 18, color: AppColors.pgnMainLine),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: Colors.grey[800]!, width: 0.5),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(children: children),
          ),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Switch row (compact, for inline use in sections)
// ═══════════════════════════════════════════════════════════════════════════════

class SettingsSwitchRow extends StatelessWidget {
  final String label;
  final String? tooltip;
  final bool value;
  final ValueChanged<bool> onChanged;

  const SettingsSwitchRow({
    super.key,
    required this.label,
    this.tooltip,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final row = Row(
      children: [
        Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
        Switch(
          value: value,
          onChanged: onChanged,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ],
    );
    if (tooltip == null) return row;
    return Tooltip(message: tooltip!, child: row);
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Switch tile (wider, for use inside SettingsGroup cards)
// ═══════════════════════════════════════════════════════════════════════════════

class SettingsSwitchTile extends StatelessWidget {
  final String label;
  final String? tooltip;
  final bool value;
  final ValueChanged<bool> onChanged;

  const SettingsSwitchTile({
    super.key,
    required this.label,
    this.tooltip,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final tile = SwitchListTile(
      title: Text(label, style: const TextStyle(fontSize: 13)),
      value: value,
      onChanged: onChanged,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      dense: true,
    );
    if (tooltip == null) return tile;
    return Tooltip(message: tooltip!, child: tile);
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Slider tile (for SettingsScreen)
// ═══════════════════════════════════════════════════════════════════════════════

class SettingsSliderTile extends StatelessWidget {
  final String label;
  final String? tooltip;
  final int value;
  final int min;
  final int max;
  final int? divisions;
  final String? suffix;
  final ValueChanged<int> onChanged;

  const SettingsSliderTile({
    super.key,
    required this.label,
    this.tooltip,
    required this.value,
    required this.min,
    required this.max,
    this.divisions,
    this.suffix,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    // Clamp defensively: persisted values (or a machine with fewer cores than
    // when prefs were written) can fall outside [min, max], and Slider asserts
    // on out-of-range values and on divisions == 0.
    final clamped = value.clamp(min, max);
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 180,
            child: Text(label, style: const TextStyle(fontSize: 13)),
          ),
          Expanded(
            child: Slider(
              value: clamped.toDouble(),
              min: min.toDouble(),
              max: max.toDouble(),
              divisions: divisions ?? (max > min ? max - min : 1),
              label: '$clamped',
              onChanged: (v) => onChanged(v.round()),
            ),
          ),
          SizedBox(
            width: 60,
            child: Text(
              suffix != null ? '$value $suffix' : '$value',
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey[400],
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
    if (tooltip == null) return content;
    return Tooltip(message: tooltip!, child: content);
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Integer stepper (compact +/- with text field)
// ═══════════════════════════════════════════════════════════════════════════════

class SettingsIntSpec {
  final String label;
  final String? tooltip;
  final int value;
  final int min;
  final int max;
  final int step;
  final ValueChanged<int> onChanged;

  const SettingsIntSpec({
    required this.label,
    this.tooltip,
    required this.value,
    required this.min,
    required this.max,
    this.step = 1,
    required this.onChanged,
  });
}

class SettingsIntGrid extends StatelessWidget {
  final List<SettingsIntSpec> fields;
  const SettingsIntGrid({super.key, required this.fields});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 0,
      children: [
        for (final f in fields)
          SizedBox(width: 150, child: _CompactIntField(spec: f)),
      ],
    );
  }
}

class _CompactIntField extends StatefulWidget {
  final SettingsIntSpec spec;
  const _CompactIntField({required this.spec});

  @override
  State<_CompactIntField> createState() => _CompactIntFieldState();
}

class _CompactIntFieldState extends State<_CompactIntField> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: '${widget.spec.value}');
  }

  @override
  void didUpdateWidget(_CompactIntField old) {
    super.didUpdateWidget(old);
    if (old.spec.value != widget.spec.value && !_ctrl.text.contains('.')) {
      final sel = _ctrl.selection;
      _ctrl.text = '${widget.spec.value}';
      if (sel.isValid && sel.end <= _ctrl.text.length) {
        _ctrl.selection = sel;
      }
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final n = int.tryParse(_ctrl.text);
    if (n != null) {
      widget.spec.onChanged(n.clamp(widget.spec.min, widget.spec.max));
    } else {
      _ctrl.text = '${widget.spec.value}';
    }
  }

  @override
  Widget build(BuildContext context) {
    final spec = widget.spec;
    final field = Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(spec.label, style: const TextStyle(fontSize: 12)),
          ),
          IconButton(
            icon: const Icon(Icons.remove, size: 18),
            onPressed: spec.value > spec.min
                ? () => spec.onChanged(
                    (spec.value - spec.step).clamp(spec.min, spec.max),
                  )
                : null,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
          SizedBox(
            width: 40,
            child: TextField(
              controller: _ctrl,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(vertical: 6),
              ),
              onSubmitted: (_) => _submit(),
              onEditingComplete: _submit,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.add, size: 18),
            onPressed: spec.value < spec.max
                ? () => spec.onChanged(
                    (spec.value + spec.step).clamp(spec.min, spec.max),
                  )
                : null,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
        ],
      ),
    );
    if (spec.tooltip == null) return field;
    return Tooltip(message: spec.tooltip!, child: field);
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Labeled dropdown
// ═══════════════════════════════════════════════════════════════════════════════

class SettingsDropdown<T> extends StatelessWidget {
  final String label;
  final String? tooltip;
  final T value;
  final List<(T, String)> items;
  final ValueChanged<T?> onChanged;

  const SettingsDropdown({
    super.key,
    required this.label,
    this.tooltip,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final field = DropdownButtonFormField<T>(
      initialValue: value,
      isExpanded: true,
      isDense: true,
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(fontSize: 12),
        border: const OutlineInputBorder(),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      ),
      items: items
          .map((e) => DropdownMenuItem(value: e.$1, child: Text(e.$2)))
          .toList(),
      onChanged: onChanged,
    );
    if (tooltip == null) return field;
    return Tooltip(message: tooltip!, child: field);
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Text field row
// ═══════════════════════════════════════════════════════════════════════════════

class SettingsTextFieldRow extends StatelessWidget {
  final String label;
  final String? tooltip;
  final TextEditingController controller;
  final ValueChanged<String> onSubmitted;

  const SettingsTextFieldRow({
    super.key,
    required this.label,
    this.tooltip,
    required this.controller,
    required this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    final field = TextField(
      controller: controller,
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(fontSize: 12),
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      onSubmitted: onSubmitted,
    );
    if (tooltip == null) return field;
    return Tooltip(message: tooltip!, child: field);
  }
}

/// Shared building blocks for settings surfaces.
///
/// Used by [SettingsScreen] (global) and the per-surface settings dialogs
/// (Stockfish, on-the-fly expectimax, analysis panels) to avoid duplicated
/// private helpers.
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

  /// One line under the heading saying what the group is for, so the user
  /// can skip whole sections instead of reading every row.
  final String? subtitle;

  const SettingsGroup({
    super.key,
    required this.title,
    required this.icon,
    required this.children,
    this.subtitle,
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
        if (subtitle != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              subtitle!,
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.onSurfaceMuted,
                height: 1.3,
              ),
            ),
          ),
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: AppColors.divider, width: 0.5),
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
    // Label and value sit on one line with the track below and capped at a
    // readable width: a full-window track puts the number so far from its
    // name that the pair has to be read twice.
    final content = Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(label, style: const TextStyle(fontSize: 13)),
              ),
              const SizedBox(width: 12),
              Text(
                suffix != null ? '$value $suffix' : '$value',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.onSurfaceSoft,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 340),
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              ),
              child: Slider(
                value: clamped.toDouble(),
                min: min.toDouble(),
                max: max.toDouble(),
                divisions: divisions ?? (max > min ? max - min : 1),
                label: '$clamped',
                onChanged: (v) => onChanged(v.round()),
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

// ═══════════════════════════════════════════════════════════════════════════════
// Dialog frame for the per-surface settings dialogs
// ═══════════════════════════════════════════════════════════════════════════════

/// Chrome shared by the per-surface settings dialogs (Stockfish, on-the-fly
/// expectimax, analysis panels): a fixed title bar with icon and close button
/// above a scrolling body. Short content shrink-wraps instead of leaving a
/// half-empty fixed-height dialog.
Future<void> showSettingsDialog(
  BuildContext context, {
  required IconData icon,
  required String title,
  required WidgetBuilder bodyBuilder,
}) async {
  // Let whatever opened this (popup menu, overlay) finish closing first.
  await Future<void>.delayed(Duration.zero);
  if (!context.mounted) return;

  final size = MediaQuery.sizeOf(context);
  final width = (size.width - 32).clamp(320.0, 560.0);
  final maxHeight = (size.height - 32).clamp(320.0, 520.0);

  await showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SizedBox(
          width: width,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _SettingsDialogTitleBar(icon: icon, title: title),
              const Divider(height: 1, color: AppColors.divider),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  child: Builder(builder: bodyBuilder),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _SettingsDialogTitleBar extends StatelessWidget {
  final IconData icon;
  final String title;

  const _SettingsDialogTitleBar({required this.icon, required this.title});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 8, 8),
      child: Row(
        children: [
          Icon(icon, color: theme.colorScheme.primary, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Close',
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }
}

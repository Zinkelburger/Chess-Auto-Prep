/// Shared building blocks for settings surfaces.
///
/// Used by [SettingsScreen] (global) and the per-surface settings dialogs
/// (Stockfish, analysis panels) to avoid duplicated
/// private helpers.
library;

import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import '../common/choice_field.dart';
import '../common/number_stepper.dart';

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

  /// Optional control pinned to the right of the heading (a help ⓘ, a link).
  final Widget? trailing;

  const SettingsGroup({
    super.key,
    required this.title,
    required this.icon,
    required this.children,
    this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Material(
        color: AppColors.surfaceElevated,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AppColors.divider),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(icon, size: 20, color: AppColors.onSurfaceMuted),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(title, style: AppTextStyles.bodyStrong),
                      ),
                      ?trailing,
                    ],
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 10),
                    Text(subtitle!, style: AppTextStyles.muted),
                  ],
                ],
              ),
            ),
            if (children.isNotEmpty) ...[
              const Divider(height: 1, color: AppColors.divider),
              ...children,
            ],
          ],
        ),
      ),
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
                  fontFamily: AppTextStyles.monoFamily,
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
// Number row: name + plain-English explanation left, − value + stepper right
// ═══════════════════════════════════════════════════════════════════════════════

/// A numeric setting as a stepper rather than a slider. A slider reads as a
/// scrollbar, hides the value until you drag it, and makes "one more core"
/// a pixel-accuracy problem; −/+ says the number out loud and moves by one,
/// and the number itself is a text box for when the target is far away.
class SettingsStepperTile extends StatelessWidget {
  final String label;

  /// Plain-English second line: what changing this actually does.
  final String? description;
  final int value;
  final int min;
  final int max;
  final int step;

  /// Trails the number ("of 16 cores"), for scale.
  final String? suffix;
  final ValueChanged<int> onChanged;

  const SettingsStepperTile({
    super.key,
    required this.label,
    this.description,
    required this.value,
    required this.min,
    required this.max,
    this.step = 1,
    this.suffix,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    // Persisted values can outlive the machine they were written on (fewer
    // cores today than yesterday), so never render an out-of-range number.
    final clamped = value.clamp(min, max);
    return SettingsValueRow(
      label: label,
      description: description,
      control: NumberStepper(
        value: clamped,
        min: min,
        max: max,
        step: step,
        suffix: suffix,
        onChanged: onChanged,
      ),
    );
  }
}

/// A labelled preference that stacks its control below the copy in narrow panes.
/// A labelled preference whose value is one of a list — the settings-panel
/// wrapper around [ChoiceField].
///
/// It used to hold a `DropdownButton`. It does not any more: a settings list
/// is exactly the case [ChoiceField] exists for, so the choice can be typed
/// at instead of hunted for in a menu.
class SettingsChoiceTile<T> extends StatelessWidget {
  const SettingsChoiceTile({
    super.key,
    required this.label,
    this.description,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final String label;
  final String? description;
  final T value;

  /// `(value, label)` pairs, in the order they should be offered.
  final List<(T, String)> items;

  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => SettingsValueRow(
    label: label,
    description: description,
    // Bounded: in the wide layout [SettingsValueRow] puts the control in a
    // Row, and a text field — which is what a ChoiceField is — has no width of
    // its own there. The `DropdownButton` this replaced sized itself.
    control: SizedBox(
      width: 240,
      child: ChoiceField<T>(
        value: value,
        items: [
          for (final (itemValue, itemLabel) in items)
            ChoiceItem<T>(value: itemValue, label: itemLabel),
        ],
        onChanged: onChanged,
      ),
    ),
  );
}

class SettingsValueRow extends StatelessWidget {
  const SettingsValueRow({
    super.key,
    required this.label,
    this.description,
    required this.control,
  });

  final String label;
  final String? description;
  final Widget control;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final labelBlock = _LabelBlock(
            label: label,
            description: description,
          );
          final labelledControl = Semantics(label: label, child: control);
          if (constraints.maxWidth < 480) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                labelBlock,
                const SizedBox(height: 12),
                labelledControl,
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: labelBlock),
              const SizedBox(width: 32),
              labelledControl,
            ],
          );
        },
      ),
    );
  }
}

class _LabelBlock extends StatelessWidget {
  const _LabelBlock({required this.label, this.description});

  final String label;
  final String? description;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: AppTextStyles.bodyStrong),
        if (description != null) ...[
          const SizedBox(height: 6),
          Text(description!, style: AppTextStyles.muted),
        ],
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Integer grid (label + compact typeable stepper, several per row)
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
          SizedBox(width: 176, child: _CompactIntField(spec: f)),
      ],
    );
  }
}

class _CompactIntField extends StatelessWidget {
  final SettingsIntSpec spec;
  const _CompactIntField({required this.spec});

  @override
  Widget build(BuildContext context) {
    final field = Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(spec.label, style: const TextStyle(fontSize: 12)),
          ),
          NumberStepper(
            value: spec.value,
            min: spec.min,
            max: spec.max,
            step: spec.step,
            onChanged: spec.onChanged,
            fieldWidth: 40,
            bordered: false,
          ),
        ],
      ),
    );
    if (spec.tooltip == null) return field;
    return Tooltip(message: spec.tooltip!, child: field);
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

/// Chrome shared by the per-surface settings dialogs (Stockfish, analysis
/// panels): a fixed title bar with icon and close button
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

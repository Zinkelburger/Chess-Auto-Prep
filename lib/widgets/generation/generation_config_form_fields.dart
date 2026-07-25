part of 'generation_config_form.dart';

mixin _GenerationConfigFields on _GenerationConfigFormStateBase {
  /// Numeric text field.  When [defaultText] is given, the label gains a
  /// "•" marker while the current value differs from it and the helper line
  /// shows the default, so modified knobs are visible at a glance.  When
  /// disabled, [disabledReason] renders as the helper line — the control
  /// explains its inertness instead of silently doing nothing.
  Widget _numField(
    TextEditingController controller,
    String label, {
    String? tooltip,
    bool enabled = true,
    String? defaultText,
    String? disabledReason,
    VoidCallback? onEdited,
  }) {
    final isEnabled = enabled && !widget.isGenerating;
    // Numeric comparison keeps '0.8' vs '0.80' from reading as modified.
    final current = controller.text.trim();
    final currentNum = double.tryParse(current);
    final defaultNum = defaultText == null
        ? null
        : double.tryParse(defaultText);
    final modified =
        defaultText != null &&
        (currentNum != null && defaultNum != null
            ? currentNum != defaultNum
            : current != defaultText);
    final String? helper = !enabled && disabledReason != null
        ? disabledReason
        : (defaultText != null ? 'default $defaultText' : null);
    final field = SizedBox(
      width: 210,
      child: TextField(
        controller: controller,
        enabled: isEnabled,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        onChanged: onEdited == null ? null : (_) => onEdited(),
        decoration: InputDecoration(
          labelText: modified ? '$label •' : label,
          helperText: helper,
          helperMaxLines: 2,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
    if (tooltip == null) return field;
    return Tooltip(message: tooltip, child: field);
  }

  Widget _toggleSwitch(
    String label,
    bool value,
    ValueChanged<bool> onChanged, {
    String? tooltip,
    bool enabled = true,
    String? disabledReason,
  }) {
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: enabled ? null : AppColors.onSurfaceMuted,
          ),
        ),
        const SizedBox(width: 4),
        Switch(
          value: value,
          onChanged: enabled && !widget.isGenerating ? onChanged : null,
        ),
      ],
    );
    final message = !enabled && disabledReason != null
        ? disabledReason
        : tooltip;
    if (message == null) return row;
    return Tooltip(message: message, child: row);
  }

  /// Labelled checkbox with an optional info tooltip, used across the
  /// advanced dialog (replaces the hand-rolled checkbox+GestureDetector
  /// rows).
  Widget _labeledCheckbox(
    String label,
    bool value,
    ValueChanged<bool> onChanged, {
    String? tooltip,
    bool enabled = true,
    String? disabledReason,
  }) {
    final isEnabled = enabled && !widget.isGenerating;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Checkbox(
          value: value,
          onChanged: isEnabled ? (v) => onChanged(v ?? false) : null,
        ),
        GestureDetector(
          onTap: isEnabled ? () => onChanged(!value) : null,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: enabled ? null : AppColors.onSurfaceMuted,
            ),
          ),
        ),
        if (tooltip != null || (!enabled && disabledReason != null)) ...[
          const SizedBox(width: 4),
          Tooltip(
            message: !enabled && disabledReason != null
                ? disabledReason
                : tooltip!,
            child: Icon(
              Icons.info_outline,
              size: 16,
              color: AppColors.onSurfaceMuted,
            ),
          ),
        ],
      ],
    );
  }

  /// Muted single-line caption under a control.
  Widget _caption(String text) => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Text(text, style: AppTextStyles.caption.copyWith(fontSize: 11)),
  );
}

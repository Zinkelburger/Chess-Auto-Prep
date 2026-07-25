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

  /// [AppCheckbox] with the form-wide isGenerating lock folded in. Every
  /// boolean in this form is a deferred option applied at Start, so per the
  /// labeled_toggle rule they are all checkboxes — no switches here.
  Widget _labeledCheckbox(
    String label,
    bool value,
    ValueChanged<bool> onChanged, {
    String? tooltip,
    bool enabled = true,
    String? disabledReason,
  }) {
    return AppCheckbox(
      label: label,
      value: value,
      onChanged: onChanged,
      tooltip: tooltip,
      enabled: enabled && !widget.isGenerating,
      disabledReason: !enabled ? disabledReason : null,
    );
  }

  /// Muted single-line caption under a control.
  Widget _caption(String text) => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Text(text, style: AppTextStyles.caption.copyWith(fontSize: 11)),
  );
}

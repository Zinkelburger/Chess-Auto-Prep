part of 'generation_config_form.dart';

mixin _GenerationConfigFields on _GenerationConfigFormStateBase {
  Widget _sectionHeader(String title) => Padding(
    padding: const EdgeInsets.only(top: 20, bottom: 8),
    child: Text(title, style: Theme.of(context).textTheme.titleSmall),
  );

  Widget _numField(
    TextEditingController controller,
    String label, {
    String? tooltip,
    bool enabled = true,
  }) {
    final field = SizedBox(
      width: 170,
      child: TextField(
        controller: controller,
        enabled: enabled && !widget.isGenerating,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: label,
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
  }) {
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: const TextStyle(fontSize: 13)),
        const SizedBox(width: 4),
        Switch(value: value, onChanged: widget.isGenerating ? null : onChanged),
      ],
    );
    if (tooltip == null) return row;
    return Tooltip(message: tooltip, child: row);
  }
}

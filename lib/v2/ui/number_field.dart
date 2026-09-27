import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

/// A number typed into a box, or stepped with − and +. Enter or leaving
/// the box takes what was typed, kept inside the row's range.
class NumberField extends StatefulWidget {
  const NumberField({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.step = 1,
    this.unit,
  });

  final String label;

  final int value;
  final int min;
  final int max;
  final int step;
  final String? unit;
  final ValueChanged<int> onChanged;

  @override
  State<NumberField> createState() => NumberFieldFieldState();
}

class NumberFieldFieldState extends State<NumberField> {
  late final _box = TextEditingController(text: '${widget.value}');
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  @override
  void didUpdateWidget(NumberField old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && !_focus.hasFocus) {
      _box.text = '${widget.value}';
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    _focus.dispose();
    _box.dispose();
    super.dispose();
  }

  void _onFocus() {
    if (!_focus.hasFocus) _typed(_box.text);
  }

  void _typed(String text) {
    if (!mounted) return;
    final typed = int.tryParse(text.trim());
    final next = (typed ?? widget.value).clamp(widget.min, widget.max);
    _box.text = '$next';
    if (next != widget.value) widget.onChanged(next);
  }

  void _step(int by) {
    if (!mounted) return;
    final next = (widget.value + by).clamp(widget.min, widget.max);
    if (next != widget.value) widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: const Icon(Icons.remove, size: IconSize.menu),
          tooltip: 'Decrease ${widget.label}',
          onPressed: widget.value > widget.min
              ? () => _step(-widget.step)
              : null,
          visualDensity: VisualDensity.compact,
        ),
        SizedBox(
          width: settingNumberWidth,
          child: TextField(
            controller: _box,
            focusNode: _focus,
            textAlign: TextAlign.center,
            style: monoText.copyWith(color: text.bodyMedium?.color),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onSubmitted: _typed,
            decoration: const InputDecoration(
              isDense: true,
              contentPadding: EdgeInsets.symmetric(
                horizontal: Space.xs,
                vertical: Space.xs,
              ),
              border: OutlineInputBorder(),
            ),
          ),
        ),
        if (widget.unit case final unit?) ...[
          const SizedBox(width: Space.xs),
          Text(unit, style: text.bodySmall),
        ],
        IconButton(
          icon: const Icon(Icons.add, size: IconSize.menu),
          tooltip: 'Increase ${widget.label}',
          onPressed: widget.value < widget.max
              ? () => _step(widget.step)
              : null,
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }
}

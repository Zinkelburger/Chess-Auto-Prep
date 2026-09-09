/// A whole number you can type or nudge.
///
/// −/+ move by [step]; the number between them is a real text box, so "16"
/// is typed, not clicked to fifteen times. Typed values are committed on
/// Enter or when the box loses focus, clamped to [min]..[max]; anything that
/// is not a number puts the previous value back.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';

class NumberStepper extends StatefulWidget {
  const NumberStepper({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.step = 1,
    this.suffix,
    this.enabled = true,
    this.fieldWidth = 52,
    this.bordered = true,
  });

  final int value;
  final int min;
  final int max;
  final int step;
  final ValueChanged<int> onChanged;

  /// Unit after the number ("MB", "s"), kept outside the text box so what is
  /// typed is only ever digits.
  final String? suffix;
  final bool enabled;
  final double fieldWidth;

  /// Draw the −/box/+ group inside one rounded border, as a settings row
  /// does. Off for a caption-sized inline use.
  final bool bordered;

  @override
  State<NumberStepper> createState() => _NumberStepperState();
}

class _NumberStepperState extends State<NumberStepper> {
  late final TextEditingController _ctrl;
  final _focus = FocusNode(debugLabel: 'NumberStepper');

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: '${widget.value}');
    _focus.addListener(_onFocus);
  }

  @override
  void didUpdateWidget(NumberStepper old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && !_focus.hasFocus) {
      _ctrl.text = '${widget.value}';
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    _focus.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  void _onFocus() {
    if (_focus.hasFocus) {
      _ctrl.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _ctrl.text.length,
      );
    } else {
      _commit();
    }
  }

  void _commit() {
    final parsed = int.tryParse(_ctrl.text.trim());
    final next = parsed == null
        ? widget.value
        : parsed.clamp(widget.min, widget.max);
    _ctrl.text = '$next';
    if (next != widget.value) widget.onChanged(next);
  }

  void _nudge(int delta) {
    final next = (widget.value + delta).clamp(widget.min, widget.max);
    _ctrl.text = '$next';
    if (next != widget.value) widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled;
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: const Icon(Icons.remove, size: 18),
          tooltip: 'Less',
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          onPressed: enabled && widget.value > widget.min
              ? () => _nudge(-widget.step)
              : null,
        ),
        SizedBox(
          width: widget.fieldWidth,
          child: FormField<int>(
            onSaved: (_) => _commit(),
            builder: (_) => TextField(
              controller: _ctrl,
              focusNode: _focus,
              enabled: enabled,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                fontFamily: AppTextStyles.monoFamily,
              ),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(vertical: 8),
              ),
              onSubmitted: (_) => _commit(),
            ),
          ),
        ),
        if (widget.suffix != null)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Text(widget.suffix!, style: AppTextStyles.caption),
          ),
        IconButton(
          icon: const Icon(Icons.add, size: 18),
          tooltip: 'More',
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          onPressed: enabled && widget.value < widget.max
              ? () => _nudge(widget.step)
              : null,
        ),
      ],
    );
    if (!widget.bordered) return row;
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.divider),
        borderRadius: BorderRadius.circular(8),
      ),
      child: row,
    );
  }
}

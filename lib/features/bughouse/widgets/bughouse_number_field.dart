/// A number you type, inside a range — the lab's one control for every
/// engine and match setting that is a quantity.
///
/// A text field rather than a dropdown of preset values, because a preset
/// list is always wrong for somebody: the hash sizes offered were never the
/// one a machine had spare, and "think for 45 seconds" was not on the menu.
/// The range is the constraint instead. A value is committed when the field
/// is submitted or loses focus, clamped into range, and the field then shows
/// what was actually kept — so typing "5" into a field whose floor is 16
/// ends with "16" in the box rather than a value the engine would refuse.
///
/// Committing on submit rather than on every keystroke matters here: most of
/// these values restart a search or reconfigure the process, and a hash of
/// "1", "10", "102", "1024" typed digit by digit is four restarts.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../theme/app_text_styles.dart';

class BughouseNumberField extends StatefulWidget {
  const BughouseNumberField({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.unit,
    this.hint,
    this.labelWidth = 72,
  });

  final String label;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  /// Printed after the number — `MB`, `s`, `nodes`.
  final String? unit;

  /// One sentence, in the label's tooltip. Never a paragraph.
  final String? hint;

  /// Width of the label column, so a stack of these lines up.
  final double labelWidth;

  @override
  State<BughouseNumberField> createState() => _BughouseNumberFieldState();
}

class _BughouseNumberFieldState extends State<BughouseNumberField> {
  late final TextEditingController _text = TextEditingController(
    text: '${widget.value}',
  );
  final FocusNode _focus = FocusNode();

  /// The last value handed to [BughouseNumberField.onChanged], or the one
  /// the widget was built with. Submitting a field also blurs it, and both
  /// commit; the second must see nothing new to say.
  late int _committed = widget.value;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  @override
  void didUpdateWidget(BughouseNumberField old) {
    super.didUpdateWidget(old);
    if (widget.value != old.value) {
      _committed = widget.value;
      if (!_focus.hasFocus) _text.text = '${widget.value}';
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    _focus.dispose();
    _text.dispose();
    super.dispose();
  }

  void _onFocus() {
    if (!_focus.hasFocus) _commit();
  }

  void _commit() {
    final parsed = int.tryParse(_text.text.trim());
    final kept = (parsed ?? _committed).clamp(widget.min, widget.max);
    _text.text = '$kept';
    if (kept == _committed) return;
    _committed = kept;
    widget.onChanged(kept);
  }

  @override
  Widget build(BuildContext context) {
    final label = Text(widget.label, style: AppTextStyles.muted);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: widget.labelWidth,
            child: widget.hint == null
                ? label
                : Tooltip(message: widget.hint!, child: label),
          ),
          Expanded(
            child: TextField(
              controller: _text,
              focusNode: _focus,
              style: AppTextStyles.mono,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _commit(),
              decoration: InputDecoration(
                isDense: true,
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 8,
                ),
                suffixText: widget.unit,
                suffixStyle: AppTextStyles.caption,
                helperText: '${widget.min}–${widget.max}',
                helperStyle: AppTextStyles.caption,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

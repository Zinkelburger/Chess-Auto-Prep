import 'package:flutter/material.dart';

import 'theme.dart';

/// A box to type a choice into, suggesting what fits as it is typed: the
/// typeable choice field the app uses instead of a drop-down menu, which
/// cannot be typed into.
///
/// Every keystroke is [onChanged]: what is typed is the value, whether or
/// not it is one of [options], so a field that takes free text — a header
/// name, a player — needs nothing more. Picking a suggestion is typing it.
/// A choice that acts at once, such as whose side a board is shown from,
/// takes [onSubmitted] instead: a picked suggestion, or the words in the box
/// when Enter finds none to pick (empty when the box was cleared).
/// Empty, it shows the magnifier that says it can be searched; once it
/// holds something it does not repeat it.
///
/// [text] is what it shows. The box follows it when it changes from
/// outside — a rule removed, a filter cleared — but not while the user is
/// typing into it, so the caret never jumps. Focused, it selects its text
/// and offers every option until something is typed; left with words that
/// chose nothing, it goes back to [text].
class ChoiceField extends StatefulWidget {
  const ChoiceField({
    super.key,
    required this.text,
    required this.options,
    this.onChanged,
    this.onSubmitted,
    required this.hint,
    this.label,
    this.enabled = true,
  });

  final String text;

  /// Everything it can suggest; those holding what is typed are shown.
  final List<String> options;

  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  /// Fallback field label, such as `Field` or `Value`.
  final String hint;

  /// The field's name, written on its border where nothing beside it
  /// names it.
  final String? label;

  /// False while the choice cannot change: shown, not typed into.
  final bool enabled;

  /// How many suggestions show at once.
  static const shown = 20;

  @override
  State<ChoiceField> createState() => _ChoiceFieldState();
}

class _ChoiceFieldState extends State<ChoiceField> {
  late final _controller = TextEditingController(text: widget.text);
  late final _focus = FocusNode()..addListener(_focusChanged);

  /// Whether the last Enter picked a suggestion.
  bool _picked = false;

  void _selected(String option) {
    _picked = true;
    widget.onChanged?.call(option);
    widget.onSubmitted?.call(option);
  }

  /// Enter picks the suggestion shown first; with none to pick, the words
  /// typed are the choice. A cleared box is submitted as it is, not as the
  /// first of every option it then offers.
  void _submit(String text, VoidCallback pick) {
    final submitted = widget.onSubmitted;
    if (submitted != null && text.trim().isEmpty) {
      submitted('');
      return;
    }
    _picked = false;
    pick();
    if (!_picked) submitted?.call(text.trim());
  }

  void _focusChanged() {
    if (_focus.hasFocus) {
      _controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _controller.text.length,
      );
    } else if (_controller.text != widget.text) {
      _controller.text = widget.text;
    }
  }

  @override
  void didUpdateWidget(ChoiceField old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && _controller.text != widget.text) {
      _controller.text = widget.text;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  Iterable<String> _suggestions(TextEditingValue value) {
    // What the box already says is not a search: every option is offered.
    final typed = value.text == widget.text
        ? ''
        : value.text.trim().toLowerCase();
    return widget.options
        .where((option) => option.toLowerCase().contains(typed))
        .take(ChoiceField.shown);
  }

  @override
  Widget build(BuildContext context) {
    return RawAutocomplete<String>(
      textEditingController: _controller,
      focusNode: _focus,
      optionsBuilder: _suggestions,
      onSelected: _selected,
      fieldViewBuilder: (context, controller, focus, submit) =>
          ValueListenableBuilder(
            valueListenable: controller,
            builder: (context, value, _) => TextField(
              controller: controller,
              focusNode: focus,
              enabled: widget.enabled,
              onChanged: widget.onChanged,
              onSubmitted: (text) => _submit(text, submit),
              // The body size, as the search box: a field in a row of
              // controls is read with them, not above them.
              style: Theme.of(context).textTheme.bodyMedium,
              decoration: InputDecoration(
                isDense: true,
                labelText: widget.label ?? widget.hint,
                floatingLabelBehavior: FloatingLabelBehavior.always,
                prefixIcon: value.text.isEmpty
                    ? const Icon(Icons.search, size: IconSize.menu)
                    : null,
                prefixIconConstraints: const BoxConstraints(
                  minWidth: IconSize.action + Space.s,
                ),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
      optionsViewBuilder: (context, pick, options) =>
          _Suggestions(options: options.toList(), onPick: pick),
    );
  }
}

/// The suggestions under the box, as a short list to click.
class _Suggestions extends StatelessWidget {
  const _Suggestions({required this.options, required this.onPick});

  final List<String> options;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topLeft,
      child: Material(
        elevation: 4,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxHeight: listRowHeight * 8,
            maxWidth: choiceFieldMenuWidth,
          ),
          child: ListView.builder(
            padding: EdgeInsets.zero,
            shrinkWrap: true,
            itemCount: options.length,
            itemBuilder: (context, index) {
              final option = options[index];
              final highlighted =
                  AutocompleteHighlightedOption.of(context) == index;
              return InkWell(
                onTap: () => onPick(option),
                child: Container(
                  height: listRowHeight,
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.symmetric(horizontal: Space.m),
                  color: highlighted
                      ? Theme.of(context).colorScheme.surfaceContainerHighest
                      : null,
                  child: Text(
                    option,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

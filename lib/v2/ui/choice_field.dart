import 'package:flutter/material.dart';

import 'theme.dart';

/// A box to type a choice into, suggesting what fits as it is typed: the
/// typeable choice field the app uses instead of a drop-down menu, which
/// cannot be typed into.
///
/// Every keystroke is [onChanged]: what is typed is the value, whether or
/// not it is one of [options], so a field that takes free text — a header
/// name, a player — needs nothing more. Picking a suggestion is typing it.
/// Empty, it shows the magnifier that says it can be searched; once it
/// holds something it does not repeat it.
///
/// [text] is what it shows. The box follows it when it changes from
/// outside — a rule removed, a filter cleared — but not while the user is
/// typing into it, so the caret never jumps.
class ChoiceField extends StatefulWidget {
  const ChoiceField({
    super.key,
    required this.text,
    required this.options,
    required this.onChanged,
    required this.hint,
  });

  final String text;

  /// Everything it can suggest; those holding what is typed are shown.
  final List<String> options;

  final ValueChanged<String> onChanged;

  /// What goes in the box, such as `Field` or `Value`.
  final String hint;

  /// How many suggestions show at once.
  static const shown = 20;

  @override
  State<ChoiceField> createState() => _ChoiceFieldState();
}

class _ChoiceFieldState extends State<ChoiceField> {
  late final _controller = TextEditingController(text: widget.text);
  final _focus = FocusNode();

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
    final typed = value.text.trim().toLowerCase();
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
      onSelected: widget.onChanged,
      fieldViewBuilder: (context, controller, focus, submit) =>
          ValueListenableBuilder(
            valueListenable: controller,
            builder: (context, value, _) => TextField(
              controller: controller,
              focusNode: focus,
              onChanged: widget.onChanged,
              onSubmitted: (_) => submit(),
              decoration: InputDecoration(
                isDense: true,
                hintText: widget.hint,
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

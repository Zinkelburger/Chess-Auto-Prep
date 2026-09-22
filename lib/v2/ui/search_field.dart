import 'package:flutter/material.dart';

import 'theme.dart';

/// The one search input: a magnifier, the words typed into it, and a clear
/// action once there is something to clear.
///
/// It rebuilds itself from the controller, so the clear button appears and
/// goes without the screen around it having to know the text.
class SearchField extends StatelessWidget {
  const SearchField({
    super.key,
    required this.controller,
    required this.hint,
    required this.onChanged,
    this.autofocus = false,
    this.onSubmitted,
  });

  final TextEditingController controller;

  /// What is being searched, such as `Search repertoires`.
  final String hint;

  final ValueChanged<String> onChanged;

  final bool autofocus;

  /// What the enter key does, when the screen has something for it to do.
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: controller,
      builder: (context, value, _) => TextField(
        controller: controller,
        autofocus: autofocus,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        decoration: InputDecoration(
          isDense: true,
          hintText: hint,
          prefixIcon: const Icon(Icons.search, size: IconSize.action),
          suffixIcon: value.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close, size: IconSize.menu),
                  tooltip: 'Clear search',
                  onPressed: () {
                    controller.clear();
                    onChanged('');
                  },
                ),
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}

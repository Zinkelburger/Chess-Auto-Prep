import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';

/// One-line filter box for any list of named things (repertoires, chapters,
/// studies, games). Always mounted, never behind a magnifier icon that has to
/// be found first — a list you cannot type into is a list you have to scroll.
///
/// Filtering itself stays with the caller: it owns the list and knows which
/// fields count as "the name".
class ListSearchField extends StatefulWidget {
  const ListSearchField({
    super.key,
    required this.hintText,
    required this.onChanged,
    this.autofocus = false,
    this.onSubmitted,
  });

  /// Says *what* is being searched ("Search repertoires"), so the box needs
  /// no separate label.
  final String hintText;
  final ValueChanged<String> onChanged;
  final bool autofocus;

  /// Enter pressed in the box. Lists that can act on the top hit (a picker
  /// that closes on it) wire this up; plain filters leave it null.
  final VoidCallback? onSubmitted;

  @override
  State<ListSearchField> createState() => _ListSearchFieldState();
}

class _ListSearchFieldState extends State<ListSearchField> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _clear() {
    _controller.clear();
    widget.onChanged('');
    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final hasText = _controller.text.isNotEmpty;
    final theme = Theme.of(context);
    OutlineInputBorder border(Color color) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(6),
      borderSide: BorderSide(color: color),
    );
    return TextField(
      controller: _controller,
      autofocus: widget.autofocus,
      style: const TextStyle(fontSize: 13),
      textInputAction: TextInputAction.search,
      onSubmitted: widget.onSubmitted == null
          ? null
          : (_) => widget.onSubmitted!(),
      onChanged: (value) {
        widget.onChanged(value);
        // Only to swap the trailing clear button in and out.
        if (!mounted) return;
        setState(() {});
      },
      decoration: InputDecoration(
        hintText: widget.hintText,
        hintStyle: AppTextStyles.caption,
        prefixIcon: const Icon(
          Icons.search,
          size: 16,
          color: AppColors.onSurfaceMuted,
        ),
        prefixIconConstraints: const BoxConstraints(
          minWidth: 32,
          minHeight: 28,
          maxHeight: 32,
        ),
        // Fixed suffix box: the field must not resize as you type.
        suffixIcon: SizedBox(
          width: 28,
          child: hasText
              ? IconButton(
                  icon: const Icon(Icons.close, size: 14),
                  tooltip: 'Clear search',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 28,
                    minHeight: 28,
                  ),
                  onPressed: _clear,
                )
              : const SizedBox.shrink(),
        ),
        suffixIconConstraints: const BoxConstraints(
          minWidth: 28,
          minHeight: 28,
          maxHeight: 32,
        ),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        border: border(AppColors.outline),
        enabledBorder: border(AppColors.outline),
        focusedBorder: border(theme.colorScheme.primary),
      ),
    );
  }
}

/// Case-insensitive "does this name contain what was typed" used by every
/// list that mounts a [ListSearchField], so filtering behaves the same
/// everywhere. Empty query matches everything.
bool matchesSearch(String query, String text) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return text.toLowerCase().contains(q);
}

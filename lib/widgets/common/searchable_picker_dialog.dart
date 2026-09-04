/// Modal "pick one of these named things" list with a type-to-filter box.
///
/// This is the home for choosers that cannot host a search box inline:
/// `DropdownButton` and `PopupMenuButton` both draw their own overlay with no
/// room for a text field, so a study with sixty chapters becomes a scroll
/// hunt. Rather than swapping affordance by list length — a control that
/// changes shape with the data is a control you have to re-learn — every
/// caller gets the same dialog. The box takes focus on open, so a long list is
/// typed down and a short one is simply clicked.
///
/// Matching is [matchesSearch] over the item's label and subtitle, the same
/// case-insensitive "contains" every other list in the app uses.
library;

import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import 'list_search_field.dart';

/// One row of a [SearchablePickerDialog].
class PickerItem<T> {
  const PickerItem({
    required this.value,
    required this.label,
    this.subtitle,
    this.icon,
    this.searchText,
  });

  /// What [showSearchablePicker] returns when this row is chosen.
  final T value;

  final String label;

  /// Second line — counts, dates, platform. Also searched.
  final String? subtitle;

  final IconData? icon;

  /// Overrides what the query matches against. Use it when a row should be
  /// findable by text it doesn't display (a game by its ECO code, say).
  final String? searchText;

  String get _haystack =>
      searchText ?? (subtitle == null ? label : '$label $subtitle');
}

/// Show the picker; resolves to the chosen value, or null if dismissed.
Future<T?> showSearchablePicker<T>({
  required BuildContext context,
  required String title,
  required String searchHint,
  required List<PickerItem<T>> items,
  T? selected,
  String emptyMessage = 'Nothing to choose from',
}) {
  return showDialog<T>(
    context: context,
    builder: (_) => SearchablePickerDialog<T>(
      title: title,
      searchHint: searchHint,
      items: items,
      selected: selected,
      emptyMessage: emptyMessage,
    ),
  );
}

class SearchablePickerDialog<T> extends StatefulWidget {
  const SearchablePickerDialog({
    super.key,
    required this.title,
    required this.searchHint,
    required this.items,
    this.selected,
    this.emptyMessage = 'Nothing to choose from',
  });

  final String title;
  final String searchHint;
  final List<PickerItem<T>> items;
  final T? selected;
  final String emptyMessage;

  @override
  State<SearchablePickerDialog<T>> createState() =>
      _SearchablePickerDialogState<T>();
}

class _SearchablePickerDialogState<T> extends State<SearchablePickerDialog<T>> {
  String _query = '';

  List<PickerItem<T>> get _visible =>
      widget.items.where((i) => matchesSearch(_query, i._haystack)).toList();

  void _pick(T value) => Navigator.of(context).pop(value);

  /// Enter takes the top hit — the payoff for typing being the fast path.
  void _pickFirst() {
    final visible = _visible;
    if (visible.isNotEmpty) _pick(visible.first.value);
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460, maxHeight: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  ListSearchField(
                    hintText: widget.searchHint,
                    autofocus: true,
                    onChanged: (v) => setState(() => _query = v),
                    onSubmitted: _pickFirst,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: visible.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 32,
                      ),
                      child: Text(
                        widget.items.isEmpty
                            ? widget.emptyMessage
                            : 'No matches for "$_query"',
                        style: const TextStyle(
                          color: AppColors.onSurfaceMuted,
                          fontSize: 13,
                        ),
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: visible.length,
                      itemBuilder: (_, index) {
                        final item = visible[index];
                        final isSelected = item.value == widget.selected;
                        return ListTile(
                          dense: true,
                          selected: isSelected,
                          leading: item.icon == null
                              ? null
                              : Icon(item.icon, size: 20),
                          title: Text(
                            item.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13),
                          ),
                          subtitle: item.subtitle == null
                              ? null
                              : Text(
                                  item.subtitle!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTextStyles.caption,
                                ),
                          trailing: isSelected
                              ? const Icon(Icons.check, size: 18)
                              : null,
                          onTap: () => _pick(item.value),
                        );
                      },
                    ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 12, 8),
              child: Row(
                children: [
                  Text(
                    '${visible.length} of ${widget.items.length}',
                    style: AppTextStyles.caption,
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

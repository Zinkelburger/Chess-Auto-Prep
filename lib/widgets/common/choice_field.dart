/// A choice you can type into.
///
/// The replacement for every form `DropdownButton` in the app: a text box
/// that shows the current choice, opens the full list when clicked or
/// focused, and narrows that list as you type. Matching is the same plain
/// case-insensitive "contains" every list in the app uses ([matchesSearch]),
/// never fuzzy — typing `sic` finds "Sicilian" and nothing that merely
/// resembles it. Arrow keys move the highlight, Enter takes it, Escape or
/// clicking away puts the previous choice back.
///
/// Two or three fixed options do not need this — a `SegmentedButton` shows
/// them all at once with nothing to open. This is for lists: engines,
/// chapters, matches, modes with names worth typing.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import 'list_search_field.dart';

/// One row of a [ChoiceField].
class ChoiceItem<T> {
  const ChoiceItem({
    required this.value,
    required this.label,
    this.subtitle,
    this.searchText,
    this.icon,
  });

  final T value;

  /// What the field shows once this is chosen, and what typing matches.
  final String label;

  /// Second, muted line in the list — a description, a count.
  final String? subtitle;

  /// Overrides what the query matches against when the label alone is not
  /// enough (a game by its ECO code, say). Defaults to label + subtitle.
  final String? searchText;

  final IconData? icon;

  String get _haystack =>
      searchText ?? (subtitle == null ? label : '$label $subtitle');
}

class ChoiceField<T> extends StatefulWidget {
  const ChoiceField({
    super.key,
    required this.items,
    required this.value,
    required this.onChanged,
    this.label,
    this.hint,
    this.helper,
    this.enabled = true,
    this.compact = false,
    this.style,
    this.emptyMessage = 'No matches',
    this.autofocus = false,
  });

  final List<ChoiceItem<T>> items;

  /// The current choice. May be a value with no item (shown as empty) or, for
  /// nullable `T`, `null` matched against an item whose value is `null`.
  final T? value;
  final ValueChanged<T> onChanged;

  /// Floating label above the text, as on any other form field.
  final String? label;

  /// Shown while nothing is chosen.
  final String? hint;

  /// One line under the field.
  final String? helper;

  final bool enabled;

  /// Borderless and tight, for a toolbar or a caption-sized row. The list
  /// that opens is the same either way.
  final bool compact;

  final TextStyle? style;
  final String emptyMessage;
  final bool autofocus;

  @override
  State<ChoiceField<T>> createState() => _ChoiceFieldState<T>();
}

class _ChoiceFieldState<T> extends State<ChoiceField<T>> {
  final _controller = TextEditingController();
  final _focus = FocusNode(debugLabel: 'ChoiceField');
  final _overlay = OverlayPortalController();
  final _link = LayerLink();
  final _scroll = ScrollController();

  /// Non-null while the user is typing; the list is filtered by it. Null
  /// means "show everything", which is what a click on the field asks for.
  String? _query;
  int _highlight = 0;
  bool _opensUp = false;
  bool? _arrowWasOpen;
  double _maxHeight = 280;

  ChoiceItem<T>? get _selected {
    for (final item in widget.items) {
      if (item.value == widget.value) return item;
    }
    return null;
  }

  List<ChoiceItem<T>> get _visible {
    final q = _query;
    if (q == null || q.trim().isEmpty) return widget.items;
    return [
      for (final item in widget.items)
        if (matchesSearch(q, item._haystack)) item,
    ];
  }

  bool get _hasSubtitles => widget.items.any((i) => i.subtitle != null);
  double get _rowHeight => _hasSubtitles ? 46 : 34;

  @override
  void initState() {
    super.initState();
    _controller.text = _selected?.label ?? '';
    _focus.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(ChoiceField<T> old) {
    super.didUpdateWidget(old);
    if (_query == null &&
        (old.value != widget.value || old.items != widget.items)) {
      _controller.text = _selected?.label ?? '';
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChanged);
    _controller.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (!mounted) return;
    if (_focus.hasFocus) {
      _open();
    } else {
      _close(revert: true);
    }
  }

  void _selectAll() {
    _controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _controller.text.length,
    );
  }

  /// Show the whole list with the current choice highlighted, and select the
  /// text so the first keystroke starts a fresh search.
  void _open() {
    if (!widget.enabled || !mounted) return;
    _measure();
    _query = null;
    final selected = _selected;
    _highlight = selected == null
        ? 0
        : math.max(0, widget.items.indexOf(selected));
    if (!_overlay.isShowing) _overlay.show();
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _selectAll();
      _scrollToHighlight();
    });
  }

  void _close({required bool revert}) {
    if (_overlay.isShowing) _overlay.hide();
    _query = null;
    if (revert) _controller.text = _selected?.label ?? '';
    if (mounted) setState(() {});
  }

  /// Decide whether the list opens below or above the field, and how tall it
  /// may be, from where the field sits on screen right now.
  void _measure() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final origin = box.localToGlobal(Offset.zero);
    final screen = MediaQuery.sizeOf(context);
    final below = screen.height - origin.dy - box.size.height - 8;
    final above = origin.dy - 8;
    _opensUp = below < 200 && above > below;
    _maxHeight = math.max(120, math.min(280, _opensUp ? above : below));
  }

  void _onTextChanged(String text) {
    _query = text;
    _highlight = 0;
    if (!_overlay.isShowing) {
      _measure();
      _overlay.show();
    }
    setState(() {});
  }

  void _pick(ChoiceItem<T> item) {
    _controller.text = item.label;
    _controller.selection = TextSelection.collapsed(offset: item.label.length);
    _close(revert: false);
    if (item.value != widget.value) widget.onChanged(item.value);
  }

  void _pickHighlighted() {
    final visible = _visible;
    if (visible.isEmpty) {
      _close(revert: true);
      return;
    }
    _pick(visible[_highlight.clamp(0, visible.length - 1)]);
  }

  void _moveHighlight(int delta) {
    final count = _visible.length;
    if (count == 0) return;
    if (!_overlay.isShowing) {
      _open();
      return;
    }
    setState(() => _highlight = (_highlight + delta).clamp(0, count - 1));
    _scrollToHighlight();
  }

  void _scrollToHighlight() {
    if (!_scroll.hasClients) return;
    final top = _highlight * _rowHeight;
    final bottom = top + _rowHeight;
    final viewTop = _scroll.offset;
    final viewBottom = viewTop + _scroll.position.viewportDimension;
    if (top < viewTop) {
      _scroll.jumpTo(top);
    } else if (bottom > viewBottom) {
      _scroll.jumpTo(bottom - _scroll.position.viewportDimension);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      _moveHighlight(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _moveHighlight(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape && _overlay.isShowing) {
      _close(revert: true);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _toggleFromArrow() {
    if (!widget.enabled) return;
    final wasOpen = _arrowWasOpen ?? _overlay.isShowing;
    _arrowWasOpen = null;
    if (wasOpen) {
      _close(revert: true);
      _focus.unfocus();
    } else {
      _focus.requestFocus();
      _open();
    }
  }

  @override
  Widget build(BuildContext context) {
    final style =
        widget.style ?? AppTextStyles.forTheme(context, AppTextStyles.body);
    // Desktop text fields gain focus on mouse-down, opening the list before
    // the arrow's mouse-up. Toggle from the state before that focus change.
    final arrow = Listener(
      onPointerDown: (_) => _arrowWasOpen = _overlay.isShowing,
      onPointerCancel: (_) => _arrowWasOpen = null,
      child: ExcludeFocus(
        child: IconButton(
          icon: Icon(
            _overlay.isShowing ? Icons.arrow_drop_up : Icons.arrow_drop_down,
            size: 20,
          ),
          tooltip: _overlay.isShowing ? 'Close list' : 'Show all',
          visualDensity: widget.compact
              ? VisualDensity.compact
              : VisualDensity.standard,
          padding: EdgeInsets.zero,
          constraints: BoxConstraints(
            minWidth: widget.compact ? 28 : 44,
            minHeight: widget.compact ? 28 : 44,
          ),
          onPressed: widget.enabled ? _toggleFromArrow : null,
        ),
      ),
    );
    final decoration = widget.compact
        ? InputDecoration(
            hintText: widget.hint,
            hintStyle: style.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            isDense: true,
            border: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 6,
              vertical: 6,
            ),
            suffixIcon: arrow,
            suffixIconConstraints: const BoxConstraints(
              minWidth: 28,
              minHeight: 28,
            ),
          )
        : InputDecoration(
            labelText: widget.label,
            hintText: widget.hint,
            helperText: widget.helper,
            helperMaxLines: 3,
            border: const OutlineInputBorder(),
            isDense: true,
            suffixIcon: arrow,
          );

    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _overlay,
        overlayChildBuilder: _buildList,
        child: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: _onKey,
          child: TextField(
            controller: _controller,
            focusNode: _focus,
            enabled: widget.enabled,
            autofocus: widget.autofocus,
            style: style,
            decoration: decoration,
            onTap: _open,
            onChanged: _onTextChanged,
            onSubmitted: (_) => _pickHighlighted(),
          ),
        ),
      ),
    );
  }

  Widget _buildList(BuildContext context) {
    final box = this.context.findRenderObject();
    final fieldWidth = box is RenderBox && box.hasSize ? box.size.width : 240.0;
    final visible = _visible;
    final width = math.max(fieldWidth, math.min(320.0, fieldWidth * 1.5));

    Widget body;
    if (visible.isEmpty) {
      body = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Text(
          widget.items.isEmpty ? 'Nothing to choose from' : widget.emptyMessage,
          style: AppTextStyles.forTheme(context, AppTextStyles.caption),
        ),
      );
    } else {
      body = ListView.builder(
        controller: _scroll,
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemExtent: _rowHeight,
        itemCount: visible.length,
        itemBuilder: (context, index) => _row(visible[index], index),
      );
    }

    return CompositedTransformFollower(
      link: _link,
      showWhenUnlinked: false,
      targetAnchor: _opensUp ? Alignment.topLeft : Alignment.bottomLeft,
      followerAnchor: _opensUp ? Alignment.bottomLeft : Alignment.topLeft,
      offset: Offset(0, _opensUp ? -4 : 4),
      child: Align(
        alignment: _opensUp ? Alignment.bottomLeft : Alignment.topLeft,
        child: ExcludeFocus(
          child: TextFieldTapRegion(
            child: Material(
              elevation: 6,
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: BorderSide(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minWidth: fieldWidth,
                  maxWidth: width,
                  maxHeight: _maxHeight,
                ),
                child: body,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(ChoiceItem<T> item, int index) {
    final highlighted = index == _highlight;
    final isSelected = item.value == widget.value;
    return MouseRegion(
      onEnter: (_) {
        if (_highlight != index) setState(() => _highlight = index);
      },
      child: InkWell(
        onTap: () => _pick(item),
        child: Container(
          color: highlighted
              ? AppColors.accent.withValues(alpha: 0.14)
              : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              if (item.icon != null) ...[
                Icon(
                  item.icon,
                  size: 18,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.forTheme(context, AppTextStyles.body)
                          .copyWith(
                            fontWeight: isSelected
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                    ),
                    if (item.subtitle != null)
                      Text(
                        item.subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.forTheme(
                          context,
                          AppTextStyles.caption,
                        ),
                      ),
                  ],
                ),
              ),
              if (isSelected) const Icon(Icons.check, size: 16),
            ],
          ),
        ),
      ),
    );
  }
}

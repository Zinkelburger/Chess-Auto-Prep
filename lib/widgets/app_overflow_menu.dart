/// Shared grouped actions menu. App bars use the visible Actions label;
/// contextual pickers can supply their own label or anchor.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_motion.dart';
import '../theme/app_text_styles.dart';
import 'info_hint.dart';

/// One row of an [AppOverflowMenu] (or of any other app menu that wants the
/// same shape).
class AppMenuEntry {
  const AppMenuEntry({
    required this.label,
    required this.onRun,
    this.icon,
    this.leading,
    this.enabled = true,
    this.dividerAbove = false,
    this.heading,
    this.checked,
    this.shortcut,
    this.hint,
    this.children = const [],
  }) : assert(
         icon == null || leading == null,
         'Give an entry an icon or a leading widget, not both.',
       );

  final List<AppMenuEntry> children;

  final String label;
  final VoidCallback onRun;

  /// Leading icon. Mutually exclusive with [leading].
  final IconData? icon;

  /// Leading widget for the rare row that needs more than an icon (a colour
  /// swatch, say). Mutually exclusive with [icon].
  final Widget? leading;

  final bool enabled;

  /// Draws a subtle inset separator above this row to distinguish groups.
  final bool dividerAbove;

  /// Uppercase section heading drawn above this row ("ADD LINES"). The first
  /// row of each group carries its group's name, with a hairline above later
  /// groups. The rule adds no extra gap around the heading.
  final String? heading;

  /// Non-null turns the row into a toggle and shows a check when true.
  final bool? checked;

  /// Keyboard shortcut hint shown right-aligned, e.g. `Ctrl+V`.
  final String? shortcut;

  /// Explanation for a row whose label genuinely cannot carry what it does —
  /// shown as a trailing hoverable ⓘ, never as a sentence under the label.
  /// Prose under every row is what turned these menus into walls of text; a
  /// hint the reader opts into costs nothing until they want it.
  final String? hint;
}

/// Labelled menu for app bars and contextual operations.
class AppOverflowMenu extends StatefulWidget {
  const AppOverflowMenu({
    super.key,
    required this.entries,
    this.tooltip = 'Actions',
    this.anchor,
    this.label = 'Actions',
    this.enabled = true,
    bool? openOnHover,
  }) : openOnHover = openOnHover ?? (label == 'Actions');

  final List<AppMenuEntry> entries;
  final String tooltip;

  /// Optional custom anchor; otherwise uses [label] (Actions by default).
  final Widget? anchor;

  /// Labelled text-and-arrow anchor. Explicit null opts into an icon anchor.
  final String? label;

  /// False greys the anchor and keeps the menu shut — for a bar that is
  /// locked while a long job runs.
  final bool enabled;

  /// Open on pointer entry; defaults to true for Actions anchors.
  /// Clicks and keyboard activation also work.
  final bool openOnHover;

  @override
  State<AppOverflowMenu> createState() => _AppOverflowMenuState();
}

class _AppOverflowMenuState extends State<AppOverflowMenu> {
  // Sibling app-bar anchors should behave as one menu strip.
  static MenuController? _activeMenu;
  final _controller = MenuController();
  Timer? _hoverExit;
  final _anchorFocus = FocusNode();
  final _firstItemFocus = FocusNode();

  @override
  void dispose() {
    if (identical(_activeMenu, _controller)) _activeMenu = null;
    _hoverExit?.cancel();
    _anchorFocus.dispose();
    _firstItemFocus.dispose();
    super.dispose();
  }

  void _keepOpen() => _hoverExit?.cancel();

  void _scheduleClose() {
    if (!widget.openOnHover) return;
    _hoverExit?.cancel();
    // Allow the pointer to cross the gap into a submenu.
    _hoverExit = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      _controller.close();
    });
  }

  Widget _hoverRegion(Widget child) => MouseRegion(
    onEnter: (_) => _keepOpen(),
    onExit: (_) => _scheduleClose(),
    child: child,
  );

  void _focusMenu() {
    if (!identical(_activeMenu, _controller)) _activeMenu?.close();
    _activeMenu = _controller;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.isOpen) return;
      _firstItemFocus.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final rows = widget.entries;
    final enabled = widget.enabled;
    final openOnHover = widget.openOnHover;
    final label = widget.label;
    final tooltip = widget.tooltip;
    if (rows.isEmpty) return const SizedBox.shrink();
    if (openOnHover || rows.any((row) => row.children.isNotEmpty)) {
      return MenuAnchor(
        style: _menuStyle,
        controller: _controller,
        childFocusNode: _anchorFocus,
        onOpen: _focusMenu,
        onClose: () {
          _hoverExit?.cancel();
          if (identical(_activeMenu, _controller)) _activeMenu = null;
        },
        menuChildren: _nestedRows(
          rows,
          firstItemFocus: _firstItemFocus,
          wrap: _hoverRegion,
        ),
        builder: (context, controller, child) => MouseRegion(
          onEnter: enabled && openOnHover
              ? (_) {
                  _keepOpen();
                  controller.open();
                }
              : null,
          onExit: (_) => _scheduleClose(),
          child: TooltipVisibility(
            visible: tooltip != label && !controller.isOpen,
            child: Tooltip(
              message: tooltip,
              child: TextButton(
                focusNode: _anchorFocus,
                style: TextButton.styleFrom(minimumSize: const Size(0, 44)),
                onPressed: !enabled
                    ? null
                    : () {
                        if (openOnHover || !controller.isOpen) {
                          controller.open();
                        } else {
                          controller.close();
                        }
                      },
                child:
                    widget.anchor ??
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          label ?? tooltip,
                          style: AppTextStyles.bodyStrong.copyWith(
                            color: enabled
                                ? AppColors.ink
                                : AppColors.onSurfaceDisabled,
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Icon(Icons.arrow_drop_down, size: 20),
                      ],
                    ),
              ),
            ),
          ),
        ),
      );
    }
    final items = <PopupMenuEntry<int>>[
      for (var i = 0; i < rows.length; i++) ...[
        if (i > 0 && (rows[i].dividerAbove || rows[i].heading != null))
          PopupMenuDivider(height: rows[i].heading != null ? 1 : 8),
        if (rows[i].heading != null) appMenuHeadingItem<int>(rows[i].heading!),
        PopupMenuItem<int>(
          value: i,
          enabled: rows[i].enabled,
          // Match the shared mode menu's row height.
          height: 32,
          child: AppMenuEntryRow(entry: rows[i]),
        ),
      ],
    ];
    final isActionsMenu = label == 'Actions';
    final anchor =
        widget.anchor ??
        (label == null
            ? null
            : Container(
                constraints: BoxConstraints(minHeight: isActionsMenu ? 44 : 0),
                padding: EdgeInsets.symmetric(
                  horizontal: isActionsMenu ? 12 : 8,
                  vertical: 6,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style:
                          (isActionsMenu
                                  ? AppTextStyles.bodyStrong
                                  : Theme.of(context).textTheme.titleMedium!)
                              .copyWith(
                                color: enabled
                                    ? AppColors.ink
                                    : AppColors.onSurfaceDisabled,
                              ),
                    ),
                    SizedBox(width: isActionsMenu ? 8 : 2),
                    Icon(
                      Icons.arrow_drop_down,
                      size: 20,
                      color: enabled
                          ? AppColors.ink
                          : AppColors.onSurfaceDisabled,
                    ),
                  ],
                ),
              ));
    return Theme(
      data: Theme.of(context).copyWith(
        dividerTheme: const DividerThemeData(
          color: AppColors.divider,
          thickness: 1,
          indent: 16,
          endIndent: 16,
        ),
      ),
      child: PopupMenuButton<int>(
        constraints: const BoxConstraints(minWidth: 240, maxWidth: 480),
        menuPadding: const EdgeInsets.symmetric(vertical: 6),
        icon: anchor == null ? const Icon(Icons.more_vert, size: 20) : null,
        tooltip: tooltip,
        enabled: enabled,
        position: anchor == null
            ? PopupMenuPosition.over
            : PopupMenuPosition.under,
        padding: anchor == null ? const EdgeInsets.all(8) : EdgeInsets.zero,
        popUpAnimationStyle: AppMotion.menuAnimation,
        onSelected: (i) => rows[i].onRun(),
        itemBuilder: (_) => items,
        child: anchor,
      ),
    );
  }
}

// Desktop menus share compact rows, with enough width and inset for labels,
// shortcuts and submenu arrows. Minimum sizes still allow scaled text to grow.
const _menuStyle = MenuStyle(
  minimumSize: WidgetStatePropertyAll(Size(240, 0)),
  padding: WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 6)),
);

const _menuItemStyle = ButtonStyle(
  minimumSize: WidgetStatePropertyAll(Size(240, 32)),
  padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 16)),
  visualDensity: VisualDensity.standard,
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
);

List<Widget> _nestedRows(
  List<AppMenuEntry> entries, {
  FocusNode? firstItemFocus,
  Widget Function(Widget)? wrap,
}) => [
  for (var i = 0; i < entries.length; i++) ...[
    if (i > 0 && (entries[i].heading != null || entries[i].dividerAbove))
      Divider(
        height: entries[i].heading != null ? 1 : 8,
        thickness: 1,
        indent: 16,
        endIndent: 16,
        color: AppColors.divider,
      ),
    if (entries[i].heading case final heading?)
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
        child: Text(heading.toUpperCase(), style: AppTextStyles.eyebrow),
      ),
    if (entries[i].children.isNotEmpty)
      SubmenuButton(
        style: _menuItemStyle,
        menuStyle: _menuStyle,
        focusNode: i == entries.indexWhere((entry) => entry.enabled)
            ? firstItemFocus
            : null,
        menuChildren: entries[i].enabled
            ? _nestedRows(entries[i].children, wrap: wrap)
            : const [],
        child: _nestedLabel(entries[i]),
      )
    else
      MenuItemButton(
        style: _menuItemStyle,
        focusNode: i == entries.indexWhere((entry) => entry.enabled)
            ? firstItemFocus
            : null,
        onPressed: entries[i].enabled ? entries[i].onRun : null,
        child: _nestedLabel(entries[i]),
      ),
  ],
].map(wrap ?? _identity).toList();

Widget _identity(Widget child) => child;

Widget _nestedLabel(AppMenuEntry entry) => Row(
  mainAxisSize: MainAxisSize.min,
  children: [
    if (entry.leading != null || entry.icon != null) ...[
      entry.leading ?? Icon(entry.icon, size: 18),
      const SizedBox(width: 12),
    ],
    Text(
      entry.label,
      style: AppTextStyles.muted.copyWith(
        fontWeight: FontWeight.w400,
        color: entry.enabled ? AppColors.ink : AppColors.onSurfaceDisabled,
      ),
    ),
    if (entry.checked == true) ...[
      const SizedBox(width: 12),
      const Icon(Icons.check, size: 16, color: AppColors.success),
    ],
    if (entry.hint != null) ...[
      const SizedBox(width: 12),
      InfoHint(entry.hint!, size: 15),
    ],
    if (entry.shortcut != null) ...[
      const SizedBox(width: 16),
      Text(entry.shortcut!, style: AppTextStyles.caption),
    ],
  ],
);

/// A non-selectable section heading row for any popup menu: the uppercase
/// eyebrow the mode switcher introduced, now shared so every grouped menu
/// in the app draws its groups the same way.
PopupMenuItem<T> appMenuHeadingItem<T>(String heading) {
  return PopupMenuItem<T>(
    enabled: false,
    height: 28,
    padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
    child: Text(heading.toUpperCase(), style: AppTextStyles.eyebrow),
  );
}

/// An [AppMenuEntry] rendered as a menu row. Public so screens with a
/// bespoke menu (the mode switcher, a picker) can still match the shape.
class AppMenuEntryRow extends StatelessWidget {
  const AppMenuEntryRow({super.key, required this.entry});

  final AppMenuEntry entry;

  @override
  Widget build(BuildContext context) {
    final muted = !entry.enabled;
    final leading =
        entry.leading ??
        (entry.icon == null
            ? null
            : Icon(
                entry.icon,
                size: 18,
                color: muted ? AppColors.onSurfaceDisabled : null,
              ));
    return Row(
      children: [
        if (leading != null) ...[
          SizedBox(width: 18, height: 18, child: Center(child: leading)),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: Text(
            entry.label,
            style: TextStyle(
              fontSize: 13,
              color: muted ? AppColors.onSurfaceDisabled : null,
            ),
          ),
        ),
        if (entry.hint != null) ...[
          const SizedBox(width: 12),
          InfoHint(entry.hint!, size: 15),
        ],
        if (entry.shortcut != null) ...[
          const SizedBox(width: 16),
          Text(entry.shortcut!, style: AppTextStyles.caption),
        ],
        if (entry.checked == true) ...[
          const SizedBox(width: 12),
          const Icon(Icons.check, size: 16, color: AppColors.success),
        ],
      ],
    );
  }
}

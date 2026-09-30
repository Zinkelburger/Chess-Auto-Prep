import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'listening_state.dart';
import 'theme.dart';

/// One thing a pane can show, by an identity that never changes — an enum
/// value, so the pane's body can switch over every tab — what the tab is
/// called and whether it can be put away.
///
/// A pinned tab is the pane's first thing, always open and first in the
/// row. The others open, close and change places like a browser's tabs.
@immutable
final class PaneTab<K extends Object> {
  const PaneTab(this.id, this.title, {this.pinned = false});

  final K id;
  final String title;
  final bool pinned;

  @override
  bool operator ==(Object other) => other is PaneTab<K> && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// Which of a pane's tabs are open, in what order, and which one is up:
/// a browser's tab bar over a fixed set of identities, the way the old
/// viewer's side panel worked. Pure state, so any pane with more than one
/// thing to show can own one, and the keys and the Actions menu can drive
/// it without touching the strip that draws it.
///
/// Closing the tab that is up brings its left neighbour forward, as the
/// old viewer did; a pinned tab cannot be closed or moved, and nothing can
/// be moved in front of it.
class PaneTabs<K extends Object> extends ChangeNotifier {
  PaneTabs(List<PaneTab<K>> tabs, {Iterable<K> open = const [], K? selected})
    : this._(List.of(tabs), _opening(tabs, open), selected);

  PaneTabs._(this.tabs, this._open, K? selected)
    : _selected = selected != null && _open.contains(selected)
          ? selected
          : _open.first;

  /// The tabs open at the start: the pinned ones, then those asked for
  /// that the pane knows, and the first tab when that leaves none.
  static List<K> _opening<K extends Object>(
    List<PaneTab<K>> tabs,
    Iterable<K> asked,
  ) {
    assert(tabs.isNotEmpty, 'a pane with no tabs has nothing to show');
    final known = {for (final tab in tabs) tab.id};
    final open = [
      for (final tab in tabs)
        if (tab.pinned) tab.id,
    ];
    for (final id in asked) {
      if (known.contains(id) && !open.contains(id)) open.add(id);
    }
    if (open.isEmpty) open.add(tabs.first.id);
    return open;
  }

  /// Every tab the pane can show, in the order they are offered.
  final List<PaneTab<K>> tabs;

  final List<K> _open;
  K _selected;

  /// The open tabs, left to right.
  List<K> get open => List.unmodifiable(_open);

  /// The one that is up.
  K get selected => _selected;

  PaneTab<K> tabOf(K id) => tabs.firstWhere((tab) => tab.id == id);

  bool isOpen(K id) => _open.contains(id);

  bool _known(K id) => tabs.any((tab) => tab.id == id);

  /// Brings [id] up, opening it at the right end first if it was closed.
  void show(K id) {
    if (!_known(id)) return;
    final wasOpen = _open.contains(id);
    if (!wasOpen) _open.add(id);
    if (wasOpen && _selected == id) return;
    _selected = id;
    notifyListeners();
  }

  /// Puts [id] away. When it was up, its left neighbour comes forward.
  void close(K id) {
    final position = _open.indexOf(id);
    if (position < 0 || tabOf(id).pinned || _open.length == 1) return;
    _open.removeAt(position);
    if (_selected == id) {
      _selected = _open[(position - 1).clamp(0, _open.length - 1)];
    }
    notifyListeners();
  }

  /// Adds a document tab, or updates its title, and brings it forward.
  void add(PaneTab<K> tab) {
    final at = tabs.indexWhere((known) => known.id == tab.id);
    if (at < 0) {
      tabs.add(tab);
    } else {
      tabs[at] = tab;
    }
    if (!_open.contains(tab.id)) _open.add(tab.id);
    _selected = tab.id;
    notifyListeners();
  }

  void remove(K id) {
    close(id);
    if (!isOpen(id)) tabs.removeWhere((tab) => tab.id == id);
  }

  void closeCurrent() => close(_selected);

  /// The tab to the right of the current one, wrapping round.
  void next() => _step(1);

  /// The tab to the left of the current one, wrapping round.
  void previous() => _step(-1);

  void _step(int by) {
    if (_open.length < 2) return;
    final at = _open.indexOf(_selected);
    _selected = _open[(at + by) % _open.length];
    notifyListeners();
  }

  /// Puts [id] in front of [before]. A pinned tab stays where it is, and
  /// nothing goes in front of it.
  void move(K id, {required K before}) {
    if (id == before || !_open.contains(id) || !_open.contains(before)) return;
    if (tabOf(id).pinned || tabOf(before).pinned) return;
    _open.remove(id);
    _open.insert(_open.indexOf(before), id);
    notifyListeners();
  }
}

/// Source identity prevents equal tool IDs in different panes from being
/// mistaken for a reorder within the same strip.
class PaneTabDrag<K extends Object> {
  const PaneTabDrag(this.source, this.id);
  final PaneTabs<K> source;
  final K id;
}

/// The row of tabs at the top of a pane: what the pane is showing, and the
/// other things it could show instead. Labels keep their natural width,
/// with a visible close button and a quiet fill for the selected tab.
/// A middle click closes a tab that can be closed, and a tab can be dragged
/// in front of another. When the tabs would be too narrow to read, the row
/// scrolls instead — the wheel scrolls it, and the tab that comes up is
/// brought into view.
///
/// The strip stays visible with one tab so navigation has a stable place.
class PaneTabStrip<K extends Object> extends StatefulWidget {
  const PaneTabStrip({
    super.key,
    required this.tabs,
    this.onSelect,
    this.onClose,
    this.onAdd,
    this.connected = false,
    this.label,
    this.showAdd = true,
    this.onContextMenu,
    this.onDragStarted,
    this.onDragEnd,
    this.onDrop,
    this.closeButtons = true,
  });

  /// Whether each tab shows a close button. Without them a tab closes with
  /// the middle button or from the menu the owner puts on the right button,
  /// so a stray click on a tab never loses it.
  final bool closeButtons;

  final ValueChanged<K>? onSelect;
  final ValueChanged<K>? onClose;
  final VoidCallback? onAdd;
  final String? label;
  final bool showAdd;
  final void Function(K, Offset)? onContextMenu;
  final ValueChanged<PaneTabDrag<K>>? onDragStarted;
  final VoidCallback? onDragEnd;
  final void Function(PaneTabDrag<K>, K)? onDrop;

  /// Inner tools join the reading surface; document tabs retain their style.
  final bool connected;

  final PaneTabs<K> tabs;

  @override
  State<PaneTabStrip<K>> createState() => _PaneTabStripState<K>();
}

class _PaneTabStripState<K extends Object> extends State<PaneTabStrip<K>>
    with ListeningState<PaneTabStrip<K>> {
  final _keys = <K, GlobalKey>{};
  final _scroll = ScrollController();
  K? _shown;

  @override
  Listenable listenableOf(PaneTabStrip<K> widget) => widget.tabs;

  @override
  void changed() => setState(() {});

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// After the frame that drew the tab that came up, scroll it into view.
  void _reveal(K id) {
    if (_shown == id) return;
    _shown = id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.tabs.selected != id) return;
      final target = _keys[id]?.currentContext;
      if (target == null) return;
      Scrollable.ensureVisible(
        target,
        alignment: 0.5,
        duration: Duration.zero,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    });
  }

  void _wheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_scroll.hasClients) return;
    final delta = event.scrollDelta.dy != 0
        ? event.scrollDelta.dy
        : event.scrollDelta.dx;
    _scroll.jumpTo(
      (_scroll.offset + delta).clamp(0.0, _scroll.position.maxScrollExtent),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tabs = widget.tabs;
    _keys.removeWhere((id, _) => !tabs.isOpen(id));
    _reveal(tabs.selected);
    return SizedBox(
      height: paneTabHeight,
      child: Row(
        children: [
          if (widget.label != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.m),
              child: Text(
                widget.label!,
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          Flexible(
            child: Listener(
              onPointerSignal: _wheel,
              child: SingleChildScrollView(
                controller: _scroll,
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final id in tabs.open)
                      ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxWidth: paneTabMaxWidth,
                          minHeight: paneTabHeight,
                          maxHeight: paneTabHeight,
                        ),
                        child: _TabSlot<K>(
                          key: _keys.putIfAbsent(id, GlobalKey.new),
                          tabs: tabs,
                          tab: tabs.tabOf(id),
                          onSelect: widget.onSelect,
                          onClose: widget.onClose,
                          connected: widget.connected,
                          closeButton: widget.closeButtons,
                          onContextMenu: widget.onContextMenu,
                          onDragStarted: widget.onDragStarted,
                          onDragEnd: widget.onDragEnd,
                          onDrop: widget.onDrop,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (widget.showAdd &&
              (widget.onAdd != null ||
                  tabs.tabs.any((tab) => !tabs.isOpen(tab.id))))
            MenuAnchor(
              menuChildren: [
                for (final tab in tabs.tabs)
                  if (!tabs.isOpen(tab.id))
                    MenuItemButton(
                      onPressed: () => tabs.show(tab.id),
                      child: Text(tab.title),
                    ),
              ],
              builder: (context, menu, _) => IconButton(
                tooltip: widget.onAdd == null ? 'Open tab' : 'New analysis tab',
                onPressed:
                    widget.onAdd ?? (menu.isOpen ? menu.close : menu.open),
                icon: const Icon(Icons.add, size: IconSize.menu),
                visualDensity: VisualDensity.compact,
              ),
            ),
        ],
      ),
    );
  }
}

/// One tab in the row, a drop target for another tab and the source of its
/// own drag. Dropping on it puts the dragged tab in front of it.
class _TabSlot<K extends Object> extends StatelessWidget {
  const _TabSlot({
    super.key,
    required this.tabs,
    required this.tab,
    required this.connected,
    required this.closeButton,
    this.onSelect,
    this.onClose,
    this.onContextMenu,
    this.onDragStarted,
    this.onDragEnd,
    this.onDrop,
  });

  final void Function(K, Offset)? onContextMenu;
  final ValueChanged<PaneTabDrag<K>>? onDragStarted;
  final VoidCallback? onDragEnd;
  final void Function(PaneTabDrag<K>, K)? onDrop;
  final ValueChanged<K>? onSelect;
  final ValueChanged<K>? onClose;

  final PaneTabs<K> tabs;
  final PaneTab<K> tab;
  final bool connected;
  final bool closeButton;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DragTarget<PaneTabDrag<K>>(
      onWillAcceptWithDetails: (details) =>
          !tab.pinned &&
          (identical(details.data.source, tabs)
              ? details.data.id != tab.id
              : onDrop != null),
      onAcceptWithDetails: (details) {
        if (identical(details.data.source, tabs)) {
          tabs.move(details.data.id, before: tab.id);
        } else {
          onDrop?.call(details.data, tab.id);
        }
      },
      builder: (context, candidates, _) => Draggable<PaneTabDrag<K>>(
        data: PaneTabDrag(tabs, tab.id),
        onDragStarted: () => onDragStarted?.call(PaneTabDrag(tabs, tab.id)),
        onDragEnd: (_) => onDragEnd?.call(),
        maxSimultaneousDrags: tab.pinned ? 0 : 1,
        feedback: Material(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(paneTabRadius),
          child: Padding(
            padding: const EdgeInsets.all(Space.s),
            child: Text(tab.title),
          ),
        ),
        childWhenDragging: Opacity(opacity: 0.4, child: _tab()),
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: candidates.isEmpty ? Colors.transparent : scheme.outline,
                width: paneTabUnderline,
              ),
            ),
          ),
          child: _tab(),
        ),
      ),
    );
  }

  Widget _tab() => GestureDetector(
    onSecondaryTapUp: onContextMenu == null
        ? null
        : (details) => onContextMenu!(tab.id, details.globalPosition),
    child: _Tab(
      title: tab.title,
      connected: connected,
      closeButton: closeButton,
      selected: tabs.selected == tab.id,
      onTap: () => (onSelect ?? tabs.show)(tab.id),
      onClose: tab.pinned || (tabs.open.length == 1 && onClose == null)
          ? null
          : () => (onClose ?? tabs.close)(tab.id),
    ),
  );
}

/// A left-aligned label and close button, without a click splash.
class _Tab extends StatelessWidget {
  const _Tab({
    required this.title,
    required this.connected,
    required this.closeButton,
    required this.selected,
    required this.onTap,
    required this.onClose,
  });

  final String title;
  final bool connected;
  final bool closeButton;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onClose;

  void _pointerDown(PointerDownEvent event) {
    if (event.buttons == kMiddleMouseButton) onClose?.call();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shape = connected
        ? const BorderRadius.vertical(top: Radius.circular(paneTabRadius))
        : BorderRadius.circular(paneTabRadius);
    return Listener(
      onPointerDown: onClose == null ? null : _pointerDown,
      child: Padding(
        padding: connected
            ? const EdgeInsets.only(top: paneTabInset, right: Space.xs)
            : const EdgeInsets.all(paneTabInset),
        child: Material(
          color: selected
              ? scheme.surfaceContainerHigh
              : scheme.surfaceContainerLow,
          shape: RoundedRectangleBorder(
            borderRadius: shape,
            side: BorderSide(
              color: selected ? scheme.outline : Colors.transparent,
            ),
          ),
          child: InkWell(
            onTap: onTap,
            borderRadius: shape,
            splashFactory: NoSplash.splashFactory,
            highlightColor: Colors.transparent,
            hoverColor: scheme.onSurface.withValues(alpha: 0.06),
            focusColor: scheme.onSurface.withValues(alpha: 0.10),
            child: Padding(
              padding: const EdgeInsets.only(left: Space.m, right: Space.xs),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      title,
                      textAlign: TextAlign.left,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontWeight: selected ? FontWeight.w600 : null,
                        color: selected
                            ? scheme.onSurface
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (onClose != null && closeButton)
                    IconButton(
                      tooltip: 'Close $title',
                      onPressed: onClose,
                      style: const ButtonStyle(
                        overlayColor: WidgetStatePropertyAll(
                          Colors.transparent,
                        ),
                        minimumSize: WidgetStatePropertyAll(
                          Size(paneTabCloseSize, paneTabCloseSize),
                        ),
                        padding: WidgetStatePropertyAll(EdgeInsets.zero),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      icon: const Icon(Icons.close, size: IconSize.menu),
                    )
                  else
                    const SizedBox(width: Space.m),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

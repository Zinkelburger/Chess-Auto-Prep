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
    : this._(tabs, _opening(tabs, open), selected);

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

  PaneTab<K> get current => tabOf(_selected);

  /// The tabs that are not open, in their offered order: what a menu can
  /// offer to show.
  List<PaneTab<K>> get closed => [
    for (final tab in tabs)
      if (!_open.contains(tab.id)) tab,
  ];

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

  /// Opens [id] at the right end without bringing it up, for something
  /// that should be there when the user looks but must not take the
  /// screen from what they are reading.
  void openInBackground(K id) {
    if (!_known(id) || _open.contains(id)) return;
    _open.add(id);
    notifyListeners();
  }

  /// Puts [id] away. When it was up, its left neighbour comes forward.
  void close(K id) {
    final position = _open.indexOf(id);
    if (position < 0 || tabOf(id).pinned) return;
    _open.removeAt(position);
    if (_selected == id) {
      _selected = _open[(position - 1).clamp(0, _open.length - 1)];
    }
    notifyListeners();
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

/// The row of tabs at the top of a pane: what the pane is showing, and the
/// other things it could show instead. The tabs share the row's width, so
/// each is a target as big as a button, and the one that is up is filled.
/// A middle click closes a tab that can be closed, and a tab can be dragged
/// in front of another. When the tabs would be too narrow to read, the row
/// scrolls instead — the wheel scrolls it, and the tab that comes up is
/// brought into view.
///
/// As in the old viewer, the row is left out while only one tab is open: a
/// row with one word in it says nothing the pane does not.
class PaneTabStrip<K extends Object> extends StatefulWidget {
  const PaneTabStrip({super.key, required this.tabs});

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
        duration: const Duration(milliseconds: 120),
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
    if (tabs.open.length < 2) return const SizedBox.shrink();
    _reveal(tabs.selected);
    List<Widget> slots() => [
      for (final id in tabs.open)
        _TabSlot<K>(
          key: _keys.putIfAbsent(id, GlobalKey.new),
          tabs: tabs,
          tab: tabs.tabOf(id),
        ),
    ];
    return SizedBox(
      height: paneTabHeight,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final fits =
              constraints.maxWidth / tabs.open.length >= paneTabMinWidth;
          if (fits) {
            return Row(
              children: [for (final slot in slots()) Expanded(child: slot)],
            );
          }
          return Listener(
            onPointerSignal: _wheel,
            child: SingleChildScrollView(
              controller: _scroll,
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final slot in slots())
                    SizedBox(width: paneTabMinWidth, child: slot),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// One tab in the row, a drop target for another tab and the source of its
/// own drag. Dropping on it puts the dragged tab in front of it.
class _TabSlot<K extends Object> extends StatelessWidget {
  const _TabSlot({super.key, required this.tabs, required this.tab});

  final PaneTabs<K> tabs;
  final PaneTab<K> tab;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DragTarget<K>(
      onWillAcceptWithDetails: (details) =>
          !tab.pinned && details.data != tab.id,
      onAcceptWithDetails: (details) => tabs.move(details.data, before: tab.id),
      builder: (context, candidates, _) => Draggable<K>(
        data: tab.id,
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
                color: candidates.isEmpty ? Colors.transparent : scheme.primary,
                width: paneTabUnderline,
              ),
            ),
          ),
          child: _tab(),
        ),
      ),
    );
  }

  Widget _tab() => _Tab(
    title: tab.title,
    selected: tabs.selected == tab.id,
    onTap: () => tabs.show(tab.id),
    onClose: tab.pinned ? null : () => tabs.close(tab.id),
  );
}

/// The word, centred on a rounded patch that is filled while the tab is
/// up and tinted under the pointer.
class _Tab extends StatelessWidget {
  const _Tab({
    required this.title,
    required this.selected,
    required this.onTap,
    required this.onClose,
  });

  final String title;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onClose;

  void _pointerDown(PointerDownEvent event) {
    if (event.buttons == kMiddleMouseButton) onClose?.call();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final shape = BorderRadius.circular(paneTabRadius);
    return Listener(
      onPointerDown: onClose == null ? null : _pointerDown,
      child: Padding(
        padding: const EdgeInsets.all(paneTabInset),
        child: Material(
          color: selected ? scheme.surfaceContainerHigh : Colors.transparent,
          borderRadius: shape,
          child: InkWell(
            onTap: onTap,
            borderRadius: shape,
            child: Center(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

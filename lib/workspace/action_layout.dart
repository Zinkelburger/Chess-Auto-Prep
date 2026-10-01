import 'package:flutter/foundation.dart';

import '../ui/app_action.dart';
import '../ui/pane_tabs.dart';
import 'explorer.dart';
import 'workspace_tabs.dart';

enum PaneSplitDirection { right, below }

sealed class ActionPaneNode {
  const ActionPaneNode();
  Iterable<int> get indices;
}

final class ActionPaneLeaf extends ActionPaneNode {
  const ActionPaneLeaf(this.index);
  final int index;
  @override
  Iterable<int> get indices => [index];
}

final class ActionPaneSplit extends ActionPaneNode {
  const ActionPaneSplit(this.direction, this.first, this.second);
  final PaneSplitDirection direction;
  final ActionPaneNode first;
  final ActionPaneNode second;
  @override
  Iterable<int> get indices => [...first.indices, ...second.indices];
}

/// Splits grow from the pane being used. Stable slots retain Explorer filters
/// when another pane is closed; the primary slot owns collection analysis.
final class ActionLayout extends ChangeNotifier {
  ActionLayout(PaneTabs<WorkspaceTab> first, this._explorer) {
    _panes.add(first);
    first.addListener(notifyListeners);
  }

  final Explorer _explorer;
  final _panes = <PaneTabs<WorkspaceTab>>[];
  final _explorers = <int, Explorer>{};
  ActionPaneNode _root = const ActionPaneLeaf(0);
  int _active = 0;

  ActionPaneNode get root => _root;
  List<int> get visible => _root.indices.toList();
  int get count => visible.length;
  int get active => _active;
  PaneTabs<WorkspaceTab> get tabs => _panes[_active];
  PaneTabs<WorkspaceTab> pane(int index) => _panes[index];
  bool isOpen(WorkspaceTab tab) => visible.any((i) => pane(i).isOpen(tab));
  int? sourceOf(PaneTabs<WorkspaceTab> tabs) {
    final index = _panes.indexOf(tabs);
    return visible.contains(index) ? index : null;
  }

  Explorer explorer(int index) => index == 0
      ? _explorer
      : _explorers.putIfAbsent(index, _explorer.independent);

  void select(int index) {
    if (!visible.contains(index) || index == _active) return;
    _active = index;
    notifyListeners();
  }

  bool canPlace(WorkspaceTab tab, int index) =>
      visible.contains(index) && pane(index).tabs.any((t) => t.id == tab);

  bool canSplit(WorkspaceTab tab) =>
      count < 4 && tab != WorkspaceTab.analysis && !pane(0).tabOf(tab).pinned;

  void show(int index, WorkspaceTab tab) {
    if (!canPlace(tab, index)) return;
    select(index);
    pane(index).show(tab);
  }

  /// Brings [tab] up in the pane that already has it open, else opens it
  /// in the pane in use: a tab is never opened twice by a request.
  void reveal(WorkspaceTab tab) {
    for (final index in visible) {
      if (pane(index).isOpen(tab)) return show(index, tab);
    }
    tabs.show(tab);
  }

  void _ensure(int index, WorkspaceTab initial) {
    while (_panes.length <= index) {
      final catalog = pane(0).tabs
          .where((tab) => tab.id != WorkspaceTab.analysis && !tab.pinned)
          .toList();
      final tabs = PaneTabs(catalog, open: [initial], selected: initial);
      tabs.addListener(notifyListeners);
      _panes.add(tabs);
    }
  }

  ActionPaneNode _replace(
    ActionPaneNode node,
    int index,
    ActionPaneNode replacement,
  ) => switch (node) {
    ActionPaneLeaf() => node.index == index ? replacement : node,
    ActionPaneSplit() => ActionPaneSplit(
      node.direction,
      _replace(node.first, index, replacement),
      _replace(node.second, index, replacement),
    ),
  };

  /// A split moves this tab if there are others; splitting a lone tab shows
  /// another view of it, as in an editor's Split command.
  void split(
    int index,
    WorkspaceTab tab,
    PaneSplitDirection direction, {
    int? from,
  }) {
    if (!visible.contains(index) || !canSplit(tab)) return;
    final fresh = [0, 1, 2, 3].firstWhere((i) => !visible.contains(i));
    _ensure(fresh, tab);
    pane(fresh).show(tab);
    for (final other in pane(fresh).open.where((id) => id != tab).toList()) {
      pane(fresh).close(other);
    }
    _root = _replace(
      _root,
      index,
      ActionPaneSplit(direction, ActionPaneLeaf(index), ActionPaneLeaf(fresh)),
    );
    if (from != null && visible.contains(from)) {
      if (from == index) {
        pane(from).close(tab);
      } else {
        _removeMovedTab(from, tab);
      }
    }
    _active = fresh;
    notifyListeners();
  }

  void move(int from, int to, WorkspaceTab tab, {WorkspaceTab? before}) {
    if (from == to ||
        !visible.contains(from) ||
        !canPlace(tab, to) ||
        !pane(from).isOpen(tab) ||
        pane(from).tabOf(tab).pinned) {
      return;
    }
    show(to, tab);
    if (before != null) pane(to).move(tab, before: before);
    _removeMovedTab(from, tab);
    _active = to;
    notifyListeners();
  }

  void _removeMovedTab(int from, WorkspaceTab tab) {
    if (pane(from).open.length == 1 && from != 0) {
      _root = _without(_root, from)!;
    } else {
      // Keep the primary pane available without opening collection analysis.
      if (pane(from).open.length == 1) {
        final available = pane(
          from,
        ).tabs.where((t) => t.id != tab && t.id != WorkspaceTab.analysis);
        pane(from).show(
          available
              .firstWhere(
                (t) => t.id == WorkspaceTab.explorer,
                orElse: () => available.first,
              )
              .id,
        );
      }
      pane(from).close(tab);
    }
  }

  /// Whether [tab] can be closed in pane [index]: the main pane keeps one
  /// tab, and closing another pane's last tab closes that pane.
  bool canClose(int index, WorkspaceTab tab) =>
      visible.contains(index) &&
      pane(index).isOpen(tab) &&
      !pane(index).tabOf(tab).pinned &&
      (index != 0 || pane(index).open.length > 1);

  void closeTab(int index, WorkspaceTab tab) {
    if (!canClose(index, tab)) return;
    if (pane(index).open.length == 1) {
      _root = _without(_root, index)!;
      if (_active == index) _active = 0;
      notifyListeners();
    } else {
      pane(index).close(tab);
    }
  }

  ActionPaneNode? _without(ActionPaneNode node, int index) {
    if (node is ActionPaneLeaf) return node.index == index ? null : node;
    final split = node as ActionPaneSplit;
    final first = _without(split.first, index);
    final second = _without(split.second, index);
    if (first == null) return second;
    if (second == null) return first;
    return ActionPaneSplit(split.direction, first, second);
  }

  void closePane(int index) {
    if (index == 0 || !visible.contains(index)) return;
    final selected = pane(0).selected;
    for (final tab in pane(index).open) {
      pane(0).show(tab);
    }
    pane(0).show(selected);
    _root = _without(_root, index)!;
    if (_active == index) _active = 0;
    notifyListeners();
  }

  void joinAll() {
    for (final index in visible.where((i) => i != 0).toList()) {
      closePane(index);
    }
  }

  /// Spatial labels follow the actual split, without visible slot numbers.
  String name(int index) {
    String? locate(ActionPaneNode node, List<String> path) {
      if (node is ActionPaneLeaf) {
        return node.index == index
            ? (path.isEmpty ? 'Main' : path.join(' · '))
            : null;
      }
      final split = node as ActionPaneSplit;
      final horizontal = split.direction == PaneSplitDirection.right;
      return locate(split.first, [...path, horizontal ? 'Left' : 'Top']) ??
          locate(split.second, [...path, horizontal ? 'Right' : 'Bottom']);
    }

    return '${locate(root, [])} — ${pane(index).selected.title}';
  }

  List<AppAction> destinations(WorkspaceTab tab, {int? from}) => [
    for (final index in visible)
      if (index != from && canPlace(tab, index))
        AppAction(
          '${from == null ? 'Open in' : 'Move to'} ${name(index)}',
          () => from == null ? show(index, tab) : move(from, index, tab),
        ),
    AppAction(
      'Split right',
      canSplit(tab)
          ? () =>
                split(from ?? active, tab, PaneSplitDirection.right, from: from)
          : null,
    ),
    AppAction(
      'Split below',
      canSplit(tab)
          ? () =>
                split(from ?? active, tab, PaneSplitDirection.below, from: from)
          : null,
    ),
  ];

  List<AppAction> get actions => [
    AppAction(
      'Split right',
      canSplit(tabs.selected)
          ? () => split(active, tabs.selected, PaneSplitDirection.right)
          : null,
      group: 'Layout',
    ),
    AppAction(
      'Split below',
      canSplit(tabs.selected)
          ? () => split(active, tabs.selected, PaneSplitDirection.below)
          : null,
      group: 'Layout',
    ),
    AppAction('Join all panes', count > 1 ? joinAll : null, group: 'Layout'),
  ];

  /// The builder's start: Moves over the Explorer on the left, Expectimax
  /// on the right, all three in view at once. The Explorer keeps the main
  /// pane, whose database and filters are the remembered ones, and the main
  /// pane keeps the other tabs to be shown by name.
  void startBuilding() {
    if (count > 1) return;
    _ensure(1, WorkspaceTab.search);
    _ensure(2, WorkspaceTab.moves);
    pane(0)
      ..show(WorkspaceTab.explorer)
      ..close(WorkspaceTab.search)
      ..close(WorkspaceTab.moves);
    _root = const ActionPaneSplit(
      PaneSplitDirection.right,
      ActionPaneSplit(
        PaneSplitDirection.below,
        ActionPaneLeaf(2),
        ActionPaneLeaf(0),
      ),
      ActionPaneLeaf(1),
    );
    _active = 1;
    notifyListeners();
  }

  /// Initial arrangements retained for fixtures and callers restoring a layout.
  void arrange(int count) {
    if (count < 1 || count > 4) return;
    for (var i = 1; i < count; i++) {
      _ensure(i, WorkspaceTab.explorer);
    }
    const a = ActionPaneLeaf(0),
        b = ActionPaneLeaf(1),
        c = ActionPaneLeaf(2),
        d = ActionPaneLeaf(3);
    _root = switch (count) {
      1 => a,
      2 => const ActionPaneSplit(PaneSplitDirection.right, a, b),
      3 => const ActionPaneSplit(
        PaneSplitDirection.right,
        a,
        ActionPaneSplit(PaneSplitDirection.below, b, c),
      ),
      _ => const ActionPaneSplit(
        PaneSplitDirection.right,
        ActionPaneSplit(PaneSplitDirection.below, a, c),
        ActionPaneSplit(PaneSplitDirection.below, b, d),
      ),
    };
    if (!visible.contains(active)) _active = 0;
    notifyListeners();
  }

  @override
  void dispose() {
    for (final pane in _panes) {
      pane.removeListener(notifyListeners);
      pane.dispose();
    }
    for (final explorer in _explorers.values) {
      explorer.dispose();
    }
    super.dispose();
  }
}

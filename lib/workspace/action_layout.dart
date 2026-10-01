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
///
/// One pane is what a mode starts as. Where [opensBeside] is set, a tab
/// picked from `+` while there is one goes under it in a pane of its own,
/// so what was being read stays in view; with more panes it joins the one
/// it was picked in. A pane can also be added empty, to be filled from its
/// `+` or by a tab dragged onto it. A pane whose last tab leaves is closed
/// and the others take its room.
final class ActionLayout extends ChangeNotifier {
  ActionLayout(
    PaneTabs<WorkspaceTab> first,
    this._explorer, {
    this.opensBeside = false,
  }) {
    _panes.add(first);
    first.addListener(notifyListeners);
  }

  final Explorer _explorer;

  /// Whether a tab picked while there is one pane opens under it in a pane
  /// of its own ([open]). A mode whose first pane cannot be read at half
  /// its height leaves this off, and a picked tab then joins that pane.
  final bool opensBeside;
  final _panes = <PaneTabs<WorkspaceTab>>[];
  final _explorers = <int, Explorer>{};

  /// The panes added empty and not filled yet. Each still has the one tab
  /// its [PaneTabs] must have, which is not shown until something is opened
  /// there.
  final _empty = <int>{};
  ActionPaneNode _root = const ActionPaneLeaf(0);
  int _active = 0;

  ActionPaneNode get root => _root;
  List<int> get visible => _root.indices.toList();
  int get count => visible.length;
  int get active => _active;
  PaneTabs<WorkspaceTab> get tabs => _panes[_active];
  PaneTabs<WorkspaceTab> pane(int index) => _panes[index];
  bool isOpen(WorkspaceTab tab) => visible.any((i) => openIn(i).contains(tab));

  /// Whether pane [index] was added empty and nothing was opened in it yet.
  bool isEmpty(int index) => _empty.contains(index);

  /// The tabs pane [index] shows, left to right: none while it is empty.
  List<WorkspaceTab> openIn(int index) =>
      isEmpty(index) ? const [] : pane(index).open;
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
    if (_empty.remove(index)) {
      for (final other in pane(index).open.where((id) => id != tab).toList()) {
        pane(index).close(other);
      }
      notifyListeners();
    }
  }

  /// Brings [tab] up in the pane that has it open; else opens it as a tab
  /// picked in the pane in use is opened ([open]). A tab is never opened
  /// twice by a request.
  void reveal(WorkspaceTab tab) {
    for (final index in visible) {
      if (openIn(index).contains(tab)) return show(index, tab);
    }
    open(active, tab);
  }

  /// A tab picked from the `+` of pane [index]. Where [opensBeside] is set
  /// and there is one pane, it goes under it in a pane of its own; a tab
  /// that cannot have one, and any tab once there are several panes, joins
  /// the pane it was picked in.
  void open(int index, WorkspaceTab tab) {
    if (!canPlace(tab, index)) return;
    if (opensBeside &&
        count == 1 &&
        !pane(index).isOpen(tab) &&
        canSplit(tab)) {
      return split(index, tab, PaneSplitDirection.below);
    }
    show(index, tab);
  }

  /// An empty pane under pane [index], the one in use until it is filled.
  void addPane(int index) {
    if (!visible.contains(index) || count >= 4) return;
    final fresh = [0, 1, 2, 3].firstWhere((i) => !visible.contains(i));
    _ensure(
      fresh,
      pane(0).tabs
          .firstWhere((tab) => tab.id != WorkspaceTab.analysis && !tab.pinned)
          .id,
    );
    _empty.add(fresh);
    _root = _replace(
      _root,
      index,
      ActionPaneSplit(
        PaneSplitDirection.below,
        ActionPaneLeaf(index),
        ActionPaneLeaf(fresh),
      ),
    );
    _active = fresh;
    notifyListeners();
  }

  /// Whether another pane can be added: four is what the card has room for,
  /// and a mode whose tabs are all pinned has nothing to put in one.
  bool get canAddPane =>
      count < 4 &&
      pane(0).tabs.any((tab) => tab.id != WorkspaceTab.analysis && !tab.pinned);

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
    _empty.remove(fresh);
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
        !openIn(from).contains(tab) ||
        pane(from).tabOf(tab).pinned) {
      return;
    }
    // The main pane cannot be closed, so when its last tab leaves for
    // another pane that pane's tabs come to it instead: one pane fewer
    // either way, holding the tabs of both.
    if (from == 0 && pane(0).open.length == 1) {
      final joining = openIn(to);
      _absorb(to);
      if (before != null) {
        pane(0).move(tab, before: before);
      } else {
        for (final other in joining) {
          pane(0).move(other, before: tab);
        }
      }
      pane(0).show(tab);
      _active = 0;
      notifyListeners();
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
      pane(from).close(tab);
    }
  }

  /// The main pane takes the tabs of pane [other], after its own, and
  /// [other] is closed.
  void _absorb(int other) {
    for (final tab in openIn(other)) {
      pane(0).show(tab);
    }
    _empty.remove(other);
    _root = _without(_root, other)!;
    if (_active == other) _active = 0;
  }

  /// The pane the main one takes the tabs of when its own last tab is
  /// closed: the first other pane with any.
  int? get _heir => visible.where((i) => i != 0 && !isEmpty(i)).firstOrNull;

  /// The pane [tab] is open in, the one in use first; null when none has it.
  int? paneOf(WorkspaceTab tab) => [
    active,
    ...visible,
  ].where((index) => openIn(index).contains(tab)).firstOrNull;

  /// Whether [tab] can be closed in pane [index]: closing a pane's last tab
  /// closes the pane, and the main pane's last tab closes only while
  /// another pane has tabs to take its place.
  bool canClose(int index, WorkspaceTab tab) =>
      visible.contains(index) &&
      openIn(index).contains(tab) &&
      !pane(index).tabOf(tab).pinned &&
      (index != 0 || pane(index).open.length > 1 || _heir != null);

  void closeTab(int index, WorkspaceTab tab) {
    if (!canClose(index, tab)) return;
    if (pane(index).open.length > 1) return pane(index).close(tab);
    if (index == 0) {
      final selected = pane(_heir!).selected;
      _absorb(_heir!);
      pane(0)
        ..close(tab)
        ..show(selected);
    } else {
      _root = _without(_root, index)!;
      if (_active == index) _active = 0;
    }
    notifyListeners();
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
    _absorb(index);
    pane(0).show(selected);
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

    final shown = isEmpty(index) ? 'empty' : pane(index).selected.title;
    return '${locate(root, [])} — $shown';
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

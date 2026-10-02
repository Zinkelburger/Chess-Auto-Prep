import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../ui/app_action.dart';
import '../ui/theme.dart' show builderMovesShare;
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
  const ActionPaneSplit(
    this.direction,
    this.first,
    this.second, {
    this.share = 0.5,
  });
  final PaneSplitDirection direction;
  final ActionPaneNode first;
  final ActionPaneNode second;

  /// How much of the split [first] has, from 0 to 1: half until the mode
  /// starts otherwise or the user drags the divider.
  final double share;
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

  bool _restoring = false;
  bool get restoring => _restoring;
  double _boardFraction = 0.4;
  double get boardFraction => _boardFraction;

  void resizeBoard(double share) {
    if (!share.isFinite) return;
    final next = share.clamp(0.2, 0.8);
    if (next == _boardFraction) return;
    _boardFraction = next;
    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (!_restoring) super.notifyListeners();
  }

  String snapshot() => jsonEncode({
    'tree': _writeNode(_root),
    'active': _active,
    'board': _boardFraction,
    'book': _book?.value,
    'panes': {
      for (final i in visible)
        '$i': {
          'open': [
            for (final tab in openIn(i))
              if (tab != WorkspaceTab.analysis) tab.name,
          ],
          'selected': pane(i).selected.name,
          'empty': isEmpty(i),
        },
    },
  });

  /// Invalid saved layouts leave the current arrangement intact.
  bool restore(String saved) {
    Map<String, Object?> data;
    ActionPaneNode tree;
    try {
      final raw = jsonDecode(saved);
      if (raw is! Map<String, Object?> || raw['panes'] is! Map) return false;
      data = raw;
      tree = _readNode(data['tree']);
      final leaves = tree.indices.toList();
      if (!leaves.contains(0) ||
          leaves.length > 4 ||
          leaves.toSet().length != leaves.length)
        return false;
      final panes = data['panes'] as Map;
      if (leaves.any((i) => panes['$i'] is! Map)) return false;
    } on Object {
      return false;
    }
    final panes = data['panes'] as Map;
    final fallback = pane(
      0,
    ).tabs.firstWhere((t) => t.id != WorkspaceTab.analysis).id;
    _restoring = true;
    try {
      _root = tree;
      _empty.clear();
      for (final i in visible) {
        _ensure(i, fallback);
        final entry = panes['$i'] as Map;
        final names = entry['open'];
        final open = names is List ? names.whereType<String>() : <String>[];
        final known = {for (final t in pane(i).tabs) t.id.name: t.id};
        pane(i).restore([
          for (final name in open)
            if (name != 'analysis' && known.containsKey(name)) known[name]!,
        ], entry['selected'] == 'analysis' ? null : known[entry['selected']]);
        if (entry['empty'] == true && !pane(i).tabs.any((t) => t.pinned))
          _empty.add(i);
      }
      _active = data['active'] is int && visible.contains(data['active'])
          ? data['active'] as int
          : visible.first;
      final share = data['board'];
      _boardFraction = share is num && share.isFinite
          ? share.toDouble().clamp(0.2, 0.8)
          : 0.4;
      if (_book != null) _book!.value = data['book'] == true;
    } finally {
      _restoring = false;
    }
    notifyListeners();
    return true;
  }

  void resizeActive(double change) {
    ActionPaneSplit? parent(ActionPaneNode node) {
      if (node is! ActionPaneSplit) return null;
      return parent(node.first) ??
          parent(node.second) ??
          (node.indices.contains(active) ? node : null);
    }

    final split = parent(_root);
    if (split != null)
      resize(
        split,
        (split.share +
                (split.first.indices.contains(active) ? change : -change))
            .clamp(0.15, 0.85),
      );
  }

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
      share: node.share,
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
      _absorb(to, inItsPlace: true);
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
  /// [other] is closed. With [inItsPlace] the main pane also moves to where
  /// [other] was, so it is the main pane's old place that closes: what a
  /// pane whose last tab left looks like from outside.
  void _absorb(int other, {bool inItsPlace = false}) {
    for (final tab in openIn(other)) {
      pane(0).show(tab);
    }
    _empty.remove(other);
    if (inItsPlace) _root = _swapped(_root, 0, other);
    _root = _without(_root, other)!;
    if (_active == other) _active = 0;
  }

  /// [node] with panes [a] and [b] in each other's places.
  ActionPaneNode _swapped(ActionPaneNode node, int a, int b) => switch (node) {
    ActionPaneLeaf(:final index) =>
      index == a
          ? ActionPaneLeaf(b)
          : index == b
          ? ActionPaneLeaf(a)
          : node,
    ActionPaneSplit() => ActionPaneSplit(
      node.direction,
      _swapped(node.first, a, b),
      _swapped(node.second, a, b),
      share: node.share,
    ),
  };

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
      _absorb(_heir!, inItsPlace: true);
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
    return ActionPaneSplit(split.direction, first, second, share: split.share);
  }

  /// [split] with [share] of its room for its first side, as the divider
  /// was dragged to. The layout keeps it while the panes stay.
  void resize(ActionPaneSplit split, double share) {
    final clamped = share.clamp(0.1, 0.9);
    if (clamped == split.share) return;
    ActionPaneNode reshared(ActionPaneNode node) => switch (node) {
      ActionPaneLeaf() => node,
      ActionPaneSplit() when identical(node, split) => ActionPaneSplit(
        node.direction,
        node.first,
        node.second,
        share: clamped,
      ),
      ActionPaneSplit() => ActionPaneSplit(
        node.direction,
        reshared(node.first),
        reshared(node.second),
        share: node.share,
      ),
    };
    _root = reshared(_root);
    notifyListeners();
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

  /// Whether the opening book shows under the moves, as Lichess's book
  /// button has it; null where the layout does not offer it.
  ValueNotifier<bool>? get book => _book;
  ValueNotifier<bool>? _book;

  /// The builder's start: Moves on the left, Expectimax on the right, the
  /// moves a little narrower ([builderMovesShare]) since they wrap and the
  /// Expectimax table's columns do not. The
  /// book starts shut and opens under the moves from its button; it is the
  /// main pane's Explorer, whose database and filters are the remembered
  /// ones. The main pane keeps the other tabs to be shown by name.
  void startBuilding() {
    if (count > 1) return;
    if (_book == null) {
      _book = ValueNotifier(false)..addListener(notifyListeners);
    }
    _ensure(1, WorkspaceTab.search);
    pane(0)
      ..show(WorkspaceTab.moves)
      ..close(WorkspaceTab.search)
      ..close(WorkspaceTab.explorer);
    _root = const ActionPaneSplit(
      PaneSplitDirection.right,
      ActionPaneLeaf(0),
      ActionPaneLeaf(1),
      share: builderMovesShare,
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
    _book?.dispose();
    super.dispose();
  }
}

Object _writeNode(ActionPaneNode node) => switch (node) {
  ActionPaneLeaf(:final index) => index,
  ActionPaneSplit() => {
    'direction': node.direction.name,
    'share': node.share,
    'first': _writeNode(node.first),
    'second': _writeNode(node.second),
  },
};

ActionPaneNode _readNode(Object? raw, [int depth = 0]) {
  if (raw is int && raw >= 0 && raw < 4) return ActionPaneLeaf(raw);
  if (depth >= 3 || raw is! Map) throw const FormatException('Invalid pane');
  final direction = PaneSplitDirection.values.asNameMap()[raw['direction']];
  final share = raw['share'];
  if (direction == null || share is! num || !share.isFinite) {
    throw const FormatException('Invalid split');
  }
  return ActionPaneSplit(
    direction,
    _readNode(raw['first'], depth + 1),
    _readNode(raw['second'], depth + 1),
    share: share.toDouble().clamp(0.15, 0.85),
  );
}

import 'package:flutter/foundation.dart';

import '../ui/app_action.dart';
import '../ui/pane_tabs.dart';
import 'explorer.dart';
import 'workspace_tabs.dart';

/// Fixed slots around one shared board. Each slot keeps its own tabs and
/// Explorer filters, including while hidden by a smaller layout.
final class ActionLayout extends ChangeNotifier {
  ActionLayout(PaneTabs<WorkspaceTab> first, this._explorer) {
    _panes.add(first);
    first.addListener(notifyListeners);
  }

  final Explorer _explorer;
  final _panes = <PaneTabs<WorkspaceTab>>[];
  final _explorers = <int, Explorer>{};
  int _count = 1;
  int _active = 0;

  int get count => _count;
  int get active => _active;
  PaneTabs<WorkspaceTab> get tabs => _panes[_active];
  PaneTabs<WorkspaceTab> pane(int index) => _panes[index];

  bool isOpen(WorkspaceTab tab) =>
      _panes.take(count).any((pane) => pane.isOpen(tab));

  Explorer explorer(int index) => index == 0
      ? _explorer
      : _explorers.putIfAbsent(index, _explorer.independent);

  void select(int index) {
    if (index < 0 || index >= _count || index == _active) return;
    _active = index;
    notifyListeners();
  }

  void arrange(int count) {
    if (count < 1 || count > 4 || count == _count) return;
    while (_panes.length < count) {
      // Collection analysis replaces the shared board, so it belongs only
      // to the primary pane, where the shell gives it its own workspace.
      final catalog = _panes.first.tabs
          .where((tab) => tab.id != WorkspaceTab.analysis)
          .toList();
      final preferred = _panes.length == 1
          ? WorkspaceTab.explorer
          : WorkspaceTab.moves;
      final initial = catalog.any((tab) => tab.id == preferred)
          ? preferred
          : catalog.first.id;
      final tabs = PaneTabs(catalog, open: [initial], selected: initial);
      tabs.addListener(notifyListeners);
      _panes.add(tabs);
    }
    _count = count;
    if (_active >= count) _active = 0;
    notifyListeners();
  }

  List<AppAction> get actions => [
    for (var count = 1; count <= 4; count++)
      AppAction(
        '$count ${count == 1 ? 'pane' : 'panes'}',
        () => arrange(count),
        group: 'Layout',
      ),
    for (var index = 0; index < count; index++)
      for (final tab in _panes[index].tabs)
        AppAction('Pane ${index + 1}: ${tab.title}', () {
          select(index);
          _panes[index].show(tab.id);
        }, group: 'Action Tabs'),
  ];

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

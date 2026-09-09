import 'package:flutter/foundation.dart';

/// Stable panel identities, independent of their visible order.
class PgnWorkspace extends ChangeNotifier {
  static const game = 0;
  static const books = 1;
  static const explorer = 2;
  static const analysis = 3;
  static const tree = 4;
  static const collection = 5;
  static const filters = 6;

  final List<int> _open = [game];
  final Map<int, String> titles = {
    game: 'Game',
    books: 'My books',
    explorer: 'Database explorer',
    analysis: 'Evaluation graph',
    tree: 'Tree',
    collection: 'Collection',
    filters: 'Filter',
  };
  int _index = game;
  bool _selecting = false;
  bool _databaseTree = false;
  bool get databaseTree => _databaseTree;
  set databaseTree(bool value) {
    if (_databaseTree == value) return;
    _databaseTree = value;
    _notifySelection();
  }

  /// Controller notifications raised while a tab is being selected still
  /// describe the old board owner. Reconcile them only after the switch.
  void synchronizeTree(bool visible) {
    if (_selecting) return;
    if (visible && (index != tree || _databaseTree)) {
      _databaseTree = false;
      index = tree;
    } else if (!visible && index == tree && !_databaseTree) {
      index = game;
    }
  }

  void _notifySelection() {
    final wasSelecting = _selecting;
    _selecting = true;
    try {
      notifyListeners();
    } finally {
      _selecting = wasSelecting;
    }
  }

  int _nextId = 7;
  List<int> get openTabs => List.unmodifiable(_open);
  int get index => _index;
  set index(int value) {
    if (value == explorer) {
      _databaseTree = true;
      value = tree;
    }

    if (!titles.containsKey(value)) return;
    if (!_open.contains(value)) _open.add(value);
    _index = value;
    _notifySelection();
  }

  /// Make a panel available alongside the current reader without moving its
  /// board cursor or switching the selected tab.
  void openInBackground(int id) {
    if (!titles.containsKey(id) || _open.contains(id)) return;
    _open.add(id);
    _notifySelection();
  }

  void animateTo(int value) => index = value;
  int add(String title) {
    final id = _nextId++;
    titles[id] = title;
    return id;
  }

  void close(int id) {
    if (id == game) return;
    final position = _open.indexOf(id);
    if (position < 0) return;
    _open.removeAt(position);
    if (_index == id) _index = _open[(position - 1).clamp(0, _open.length - 1)];
    if (id >= 7) titles.remove(id);
    _notifySelection();
  }

  void next() => index = _open[(_open.indexOf(_index) + 1) % _open.length];

  void move(int id, int before) {
    if (id == game || before == game || id == before) return;
    if (!_open.contains(id) || !_open.contains(before)) return;
    _open.remove(id);
    _open.insert(_open.indexOf(before), id);
    _notifySelection();
  }
}

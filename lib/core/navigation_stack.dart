/// History trail for position navigation.
///
/// When the user clicks [Go] on a trap, hard move, or coverage suggestion,
/// the current position is pushed here. Displayed as clickable chips.
library;

import 'package:flutter/foundation.dart';

class NavigationEntry {
  final int tabIndex;
  final String fen;
  final String label;
  final String reason;

  const NavigationEntry({
    required this.tabIndex,
    required this.fen,
    required this.label,
    required this.reason,
  });
}

class NavigationStack extends ChangeNotifier {
  final List<NavigationEntry> _entries = [];
  static const int _maxEntries = 8;

  List<NavigationEntry> get entries => List.unmodifiable(_entries);
  bool get isEmpty => _entries.isEmpty;
  bool get isNotEmpty => _entries.isNotEmpty;
  int get length => _entries.length;

  void push(NavigationEntry entry) {
    _entries.add(entry);
    if (_entries.length > _maxEntries) {
      _entries.removeAt(0);
    }
    notifyListeners();
  }

  /// Jump back to a specific entry. Removes everything after it.
  NavigationEntry? jumpTo(int index) {
    if (index < 0 || index >= _entries.length) return null;
    final entry = _entries[index];
    _entries.removeRange(index, _entries.length);
    notifyListeners();
    return entry;
  }

  void clear() {
    if (_entries.isNotEmpty) {
      _entries.clear();
      notifyListeners();
    }
  }
}

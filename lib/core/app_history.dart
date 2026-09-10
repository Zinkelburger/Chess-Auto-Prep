/// App-level navigation history. Mode switches and cross-screen handoffs
/// append destinations; Back returns to the retained screen in the IndexedStack.
/// A handoff is replayed only if a later visit overwrote that mode's screen.
library;

import 'package:flutter/foundation.dart';

import '../utils/safe_change_notifier.dart';
import 'app_state.dart';

class AppHistoryEntry {
  const AppHistoryEntry({
    required this.mode,
    required this.label,
    this.handoff,
    this.restore,
    this.visitId = 0,
  });

  final AppMode mode;
  final String label;

  /// Fallback payload when a later visit has replaced this screen context.
  final PendingHandoff? handoff;

  /// Restores live screen state captured immediately before leaving.
  final VoidCallback? restore;
  final int visitId;
}

class AppHistory extends ChangeNotifier
    with SafeChangeNotifier
    implements NavigationHistoryRecorder {
  AppHistory(this._appState) {
    _entries.add(
      AppHistoryEntry(
        mode: _appState.currentMode,
        label: _appState.currentMode.label,
      ),
    );
    _appState.attachHistory(this);
  }

  final AppState _appState;
  final List<AppHistoryEntry> _entries = [];
  final Map<AppMode, int> _screenVisits = {};
  int _nextVisit = 0;
  final Map<AppMode, VoidCallback Function()> _captures = {};
  final Map<AppMode, bool Function()> _canRestore = {};

  /// Register a mounted screen's context capture. The returned function
  /// unregisters only this registration when the screen is disposed.
  VoidCallback registerContext(
    AppMode mode,
    VoidCallback Function() capture, {
    bool Function()? canRestore,
  }) {
    _captures[mode] = capture;
    if (canRestore == null) {
      _canRestore.remove(mode);
    } else {
      _canRestore[mode] = canRestore;
    }
    return () {
      if (identical(_captures[mode], capture)) {
        _captures.remove(mode);
        _canRestore.remove(mode);
      }
    };
  }

  void _captureCurrent() {
    if (_entries.isEmpty) return;
    final entry = _entries.last;
    final capture = _captures[entry.mode];
    if (capture == null) return;
    _entries[_entries.length - 1] = AppHistoryEntry(
      mode: entry.mode,
      label: entry.label,
      handoff: entry.handoff,
      restore: capture(),
      visitId: entry.visitId,
    );
  }

  /// Trail depth cap; oldest crumbs drop off. Deep trails are unreadable
  /// anyway, and the cap bounds re-delivery payload retention.
  static const int maxEntries = 8;

  /// True while this object is re-delivering an entry from [popTo]: the
  /// resulting handOff/setMode reports back into recordPush/recordReset,
  /// which must not re-record it.
  bool _redelivering = false;

  List<AppHistoryEntry> get entries => List.unmodifiable(_entries);
  int get length => _entries.length;
  bool get canGoBack => _entries.length > 1;

  @override
  void recordPush(AppMode mode, PendingHandoff? handoff, String label) {
    if (_redelivering) return;
    _captureCurrent();
    final visitId = ++_nextVisit;
    _screenVisits[mode] = visitId;
    final entry = AppHistoryEntry(
      mode: mode,
      label: label,
      handoff: handoff,
      visitId: visitId,
    );
    final last = _entries.isEmpty ? null : _entries.last;
    if (last != null && last.mode == mode && last.label == label) {
      // Same destination re-pushed (e.g. re-seeding the same repertoire):
      // refresh the payload in place instead of stacking a duplicate crumb.
      _entries[_entries.length - 1] = entry;
    } else {
      _entries.add(entry);
      if (_entries.length > maxEntries) _entries.removeAt(0);
    }
    notifyListeners();
  }

  @override
  void recordReset(AppMode mode) {
    if (_redelivering) return;
    _entries
      ..clear()
      ..add(AppHistoryEntry(mode: mode, label: mode.label));
    notifyListeners();
  }

  /// Return to an earlier destination. Retained screens keep their current
  /// board, filters, selected tab and scroll position without reloading.
  void popTo(int index) {
    if (index < 0 || index >= _entries.length - 1) return;
    final entry = _entries[index];
    final screenWasRevisited =
        (_screenVisits[entry.mode] ?? 0) != entry.visitId;
    // A replacement guard runs before changing the trail or mode. In
    // particular, a viewer with unsaved edits must stay on that collection.
    if (screenWasRevisited && _canRestore[entry.mode]?.call() == false) return;
    _entries.removeRange(index + 1, _entries.length);
    _redelivering = true;
    try {
      final handoff = entry.handoff;
      if (screenWasRevisited && entry.restore != null) {
        _appState.setMode(entry.mode);
        entry.restore!();
      } else if (screenWasRevisited && handoff != null) {
        _appState.handOff(handoff);
      } else {
        _appState.setMode(entry.mode);
      }
      _screenVisits[entry.mode] = entry.visitId;
    } finally {
      _redelivering = false;
    }
    notifyListeners();
  }

  void back() => popTo(_entries.length - 2);
}

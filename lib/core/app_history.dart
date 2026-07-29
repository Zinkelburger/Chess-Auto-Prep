/// App-level breadcrumb history: `Games ▸ Game X vs Y ▸ Repertoire "…"`.
///
/// The insight that keeps this small: [PendingHandoff] is already the app's
/// serializable "screen + payload" route object — every cross-screen jump is
/// either a bare [AppState.setMode] or a [AppState.handOff]. The history
/// therefore just records those (via [NavigationHistoryRecorder], which
/// AppState reports into), and a breadcrumb click *re-delivers* the recorded
/// handoff. Consumer screens restore themselves from a re-fired handoff
/// exactly as they do from a fresh one, so they need no changes.
///
/// Semantics:
/// - `handOff` / `pushMode` → a new crumb (same-labeled top is replaced, not
///   stacked, so re-opening the same thing can't grow `A ▸ A`).
/// - `setMode` (the mode menu) → the trail resets to that mode's root.
/// - Crumb click → truncate after it, re-deliver its handoff (or bare mode).
library;

import 'package:flutter/foundation.dart';

import '../utils/safe_change_notifier.dart';
import 'app_state.dart';

class AppHistoryEntry {
  const AppHistoryEntry({
    required this.mode,
    required this.label,
    this.handoff,
  });

  final AppMode mode;
  final String label;

  /// Payload re-delivered when this crumb is clicked; null for a bare mode
  /// root (re-delivery is then just a mode switch — the screen keeps
  /// whatever state it already has).
  final PendingHandoff? handoff;
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
    final entry = AppHistoryEntry(mode: mode, label: label, handoff: handoff);
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

  /// Breadcrumb click: drop everything after [index] and re-deliver that
  /// entry so its screen restores itself. Clicking the current (last) crumb
  /// is a no-op.
  void popTo(int index) {
    if (index < 0 || index >= _entries.length - 1) return;
    _entries.removeRange(index + 1, _entries.length);
    final entry = _entries[index];
    _redelivering = true;
    try {
      final handoff = entry.handoff;
      if (handoff != null) {
        _appState.handOff(handoff);
      } else {
        _appState.setMode(entry.mode);
      }
    } finally {
      _redelivering = false;
    }
    notifyListeners();
  }

  void back() => popTo(_entries.length - 2);
}

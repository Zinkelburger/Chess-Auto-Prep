/// Open/closed state and active tab for the [BottomPane], owned by the screen
/// rather than by the widget's `State`.
///
/// The screen used to drive the pane through a `GlobalKey<BottomPaneState>`,
/// calling `_bottomPaneKey.currentState?.open(tab)`. That reads as a method
/// call but is really a lookup that returns null whenever the pane is not
/// mounted — so "open the Findings tab" could silently do nothing, and every
/// caller had to decide what a null meant. Holding the state here instead
/// makes the calls total: the screen owns the controller for its whole
/// lifetime, and the widget renders whatever it says.
library;

import 'package:flutter/foundation.dart';

import '../../utils/safe_change_notifier.dart';

enum BottomPaneTab { findings, jobs, lines }

class BottomPaneController extends ChangeNotifier with SafeChangeNotifier {
  /// Height as a fraction of screen height, so the pane keeps its proportion
  /// when the window resizes (minimised → fullscreen).
  static const double defaultHeightFraction = 0.60;
  static const double maxHeightFraction = 0.60;
  static const double minHeightPx = 120.0;

  bool _collapsed = true;
  BottomPaneTab _activeTab = BottomPaneTab.findings;
  double _heightFraction = defaultHeightFraction;

  bool get isCollapsed => _collapsed;
  BottomPaneTab get activeTab => _activeTab;
  double get heightFraction => _heightFraction;

  /// Whether [tab] is the one the user can currently see.
  bool isShowing(BottomPaneTab tab) => !_collapsed && _activeTab == tab;

  void open(BottomPaneTab tab) {
    if (!_collapsed && _activeTab == tab) return;
    _collapsed = false;
    _activeTab = tab;
    notifyListeners();
  }

  void close() {
    if (_collapsed) return;
    _collapsed = true;
    notifyListeners();
  }

  /// Open [tab], switch to it, or close — whichever the current state implies.
  ///
  /// Collapsed → open (at [tab], or wherever it was last). Open on a different
  /// tab → switch. Open on this tab → close, so the same shortcut toggles.
  void toggle([BottomPaneTab? tab]) {
    if (_collapsed) {
      open(tab ?? _activeTab);
    } else if (tab != null && tab != _activeTab) {
      _activeTab = tab;
      notifyListeners();
    } else {
      close();
    }
  }

  void setHeightFraction(double fraction) {
    final clamped = fraction.clamp(0.0, maxHeightFraction);
    if (clamped == _heightFraction) return;
    _heightFraction = clamped;
    notifyListeners();
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Navigation lifetime belongs to the workspace, not the app's root route.
/// The observer also sees routes pushed by descendants through Navigator.of.
class WorkspaceNavigationController extends ChangeNotifier {
  WorkspaceNavigationController() {
    observer = _WorkspaceObserver(this);
  }
  final navigatorKey = GlobalKey<NavigatorState>();
  late final NavigatorObserver observer;
  final List<Route<dynamic>> _routes = [];
  bool _disposed = false;
  bool _notificationQueued = false;
  bool get hasDestination => _routes.whereType<PageRoute<dynamic>>().length > 1;

  Future<T?> push<T>(Route<T> route) {
    final navigator = navigatorKey.currentState;
    if (_disposed || navigator == null) return Future<T?>.value();
    return navigator.push(route);
  }

  Future<bool> maybePop() async =>
      !_disposed && navigatorKey.currentState != null
      ? navigatorKey.currentState!.maybePop()
      : false;

  void _changed() {
    if (_disposed || _notificationQueued) return;
    // Observer callbacks can run while Navigator builds its initial routes.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      _notificationQueued = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _notificationQueued = false;
        if (!_disposed) notifyListeners();
      });
    } else {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class _WorkspaceObserver extends NavigatorObserver {
  _WorkspaceObserver(this.owner);
  final WorkspaceNavigationController owner;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    final wasNested = owner.hasDestination;
    owner._routes.add(route);
    if (wasNested != owner.hasDestination) owner._changed();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    owner._routes.remove(route);
    owner._changed();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    owner._routes.remove(route);
    owner._changed();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : owner._routes.indexOf(oldRoute);
    if (index >= 0) {
      if (newRoute == null) {
        owner._routes.removeAt(index);
      } else {
        owner._routes[index] = newRoute;
      }
    }
    owner._changed();
  }
}

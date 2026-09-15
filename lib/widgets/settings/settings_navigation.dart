import 'package:flutter/material.dart';

import '../../core/app_state.dart';

/// View-owned settings stay attached to their live controllers. The host can
/// mount a requested owner without changing the active workspace.
class ViewSettingsRegistry extends ChangeNotifier {
  static final _registries = Expando<ViewSettingsRegistry>();
  static ViewSettingsRegistry forApp(AppState app) =>
      _registries[app] ??= ViewSettingsRegistry();

  final Map<
    AppMode,
    ({Object owner, WidgetBuilder? builder, VoidCallback? onClosed})
  >
  entries = {};

  final Set<AppMode> requestedModes = {};
  void requestView(AppMode mode) {
    if (requestedModes.add(mode)) notifyListeners();
  }

  void register(
    AppMode mode,
    Object owner,
    WidgetBuilder? builder,
    VoidCallback? onClosed,
  ) {
    entries[mode] = (owner: owner, builder: builder, onClosed: onClosed);
    notifyListeners();
  }

  void unregister(AppMode mode, Object owner) {
    if (entries[mode]?.owner == owner) {
      entries.remove(mode);
      // Disposal can happen during a build; listeners refresh next frame.
      WidgetsBinding.instance.addPostFrameCallback((_) => notifyListeners());
    }
  }
}

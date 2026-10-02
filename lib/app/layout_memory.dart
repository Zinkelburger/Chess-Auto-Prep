import 'dart:async';
import 'dart:convert';

import '../storage/settings_store.dart';
import '../workspace/action_layout.dart';
import 'mode.dart';

/// Remembers deliberate layout changes for each mode and document. File
/// navigation restores a snapshot without writing untouched defaults back.
final class LayoutMemory {
  LayoutMemory(this.settings, Map<Mode, ActionLayout> layouts)
    : _defaults = {
        for (final entry in layouts.entries) entry.key: entry.value.snapshot(),
      };
  final SettingsStore settings;
  final Map<Mode, String> _defaults;
  String? _key;
  Mode? _mode;
  ActionLayout? _layout;
  bool _restoring = false, _dirty = false;
  Timer? _timer;
  Completer<void>? _queued;

  void select(Mode mode, String? path, ActionLayout layout) {
    final key = jsonEncode([mode.name, path]);
    if (key == _key) return;
    flush();
    _layout?.removeListener(_changed);
    _key = key;
    _mode = mode;
    _layout = layout;
    _restoring = true;
    final saved = settings.value.workspaceLayouts[key];
    if (saved == null || !layout.restore(saved))
      layout.restore(_defaults[mode]!);
    _restoring = false;
    layout.addListener(_changed);
  }

  void reset() {
    final layout = _layout;
    if (layout == null) return;
    layout.restore(_defaults[_mode]!);
  }

  void _changed() {
    if (_restoring || _layout!.restoring) return;
    _dirty = true;
    if (_queued == null) {
      _queued = Completer<void>();
      settings.pendingWrites?.watch(this, _queued!.future);
    }
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 250), flush);
  }

  void flush() {
    _timer?.cancel();
    if (!_dirty || _key == null) return;
    _dirty = false;
    final value = settings.value;
    final layouts = {...value.workspaceLayouts, _key!: _layout!.snapshot()};
    final queued = _queued;
    _queued = null;
    unawaited(
      settings
          .update(value.copyWith(workspaceLayouts: layouts))
          .whenComplete(() => queued?.complete()),
    );
  }

  void dispose() {
    flush();
    _layout?.removeListener(_changed);
  }
}

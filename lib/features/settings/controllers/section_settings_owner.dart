import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../../utils/safe_change_notifier.dart';
import '../models/section_configuration.dart';
import '../models/settings_state.dart';
import '../repositories/settings_section_storage.dart';
import 'settings_section_controller.dart';

/// Application-scoped presentation owner. Consumers read committed values;
/// controls render [editing] and commands retain failures in [state].
abstract class SectionSettingsOwner<C extends SectionConfiguration<C>>
    extends ChangeNotifier
    with SafeChangeNotifier {
  SectionSettingsOwner(SettingsSectionStorage<C> storage, this.defaults)
    : _controller = SettingsSectionController(storage) {
    _subscription = _controller.changes.listen((_) => notifyListeners());
  }
  final C defaults;
  final SettingsSectionController<C> _controller;
  late final StreamSubscription<SettingsState<C>> _subscription;
  SettingsState<C> get state => _controller.state;
  C get committed => state.committed ?? defaults;
  C get editing => state.draft ?? committed;
  Future<void> ensureLoaded() => _controller.ensureLoaded();
  Future<void> reload() => _controller.reload();
  Future<void> retry() => _controller.retry();
  Future<void> edit(Map<String, Object> fields) {
    if (fields.keys.any((key) => !defaults.values.containsKey(key))) {
      return Future.error(ArgumentError('Unknown settings field'));
    }
    final normalized = editing.withValues({...editing.values, ...fields});
    return _controller.apply(
      SettingsPatch<C>({
        for (final key in fields.keys) key: normalized.values[key]!,
      }),
    );
  }

  void submit(Map<String, Object> fields) {
    if (fields.entries.every(
      (entry) => editing.values[entry.key] == entry.value,
    ))
      return;
    unawaited(edit(fields).catchError((Object _) {}));
  }

  Future<void> resetToDefaults() => edit(defaults.values);
  @override
  void dispose() {
    unawaited(_subscription.cancel());
    _controller.dispose();
    super.dispose();
  }
}

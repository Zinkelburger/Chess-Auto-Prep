import 'package:shared_preferences/shared_preferences.dart';
import '../../features/settings/models/section_configuration.dart';
import '../../features/settings/repositories/settings_section_storage.dart';

/// Only captured field edits are written, preserving unrelated preferences.
class PreferencesSectionStorage<C extends SectionConfiguration<C>>
    implements SettingsSectionStorage<C> {
  PreferencesSectionStorage({
    required this.decode,
    required this.keys,
    Future<SharedPreferences> Function()? preferences,
  }) : _preferences = preferences ?? SharedPreferences.getInstance;
  final C Function(Map<String, Object?>) decode;
  final Set<String> keys;
  final Future<SharedPreferences> Function() _preferences;
  @override
  Future<C> read() async {
    final preferences = await _preferences();
    await preferences.reload();
    return decode({for (final key in keys) key: preferences.get(key)});
  }

  @override
  Future<void> write(SettingsPatch<C> patch) async {
    final preferences = await _preferences();
    for (final entry in patch.changes.entries) {
      if (!keys.contains(entry.key))
        throw ArgumentError('Unknown preference: ${entry.key}');
      final value = entry.value;
      final written = switch (value) {
        null => await preferences.remove(entry.key),
        int() => await preferences.setInt(entry.key, value),
        bool() => await preferences.setBool(entry.key, value),
        String() => await preferences.setString(entry.key, value),
        _ => throw ArgumentError('Unsupported preference: ${entry.key}'),
      };
      if (!written) throw StateError('Could not save ${entry.key}');
    }
  }
}

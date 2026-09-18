/// Immutable scalar preferences (including explicit nullable values) for one independently committed section.
abstract class SectionConfiguration<C> {
  Map<String, Object?> get values;
  C withValues(Map<String, Object?> values);
}

class SettingsPatch<C extends SectionConfiguration<C>> {
  /// Absent keys are unchanged; present null values remove their preference.
  SettingsPatch(Map<String, Object?> changes)
    : changes = Map.unmodifiable(changes);
  final Map<String, Object?> changes;
  bool get isEmpty => changes.isEmpty;
  C apply(C configuration) =>
      configuration.withValues({...configuration.values, ...changes});
  SettingsPatch<C> followedBy(SettingsPatch<C> next) =>
      SettingsPatch({...changes, ...next.changes});
  SettingsPatch<C> without(Iterable<String> keys) =>
      SettingsPatch({...changes}..removeWhere((key, _) => keys.contains(key)));
}

abstract class ImmutableSection<C> implements SectionConfiguration<C> {
  ImmutableSection(Map<String, Object?> values)
    : values = Map.unmodifiable(values);
  @override
  final Map<String, Object?> values;
  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType &&
      other is ImmutableSection<C> &&
      values.length == other.values.length &&
      values.entries.every((entry) => other.values[entry.key] == entry.value);
  @override
  int get hashCode => Object.hashAll(
    values.entries.map((entry) => Object.hash(entry.key, entry.value)),
  );
}

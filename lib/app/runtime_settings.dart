import '../features/settings/controllers/eval_database_settings.dart';
import '../features/settings/models/eval_database_configuration.dart';
import '../features/settings/controllers/engine_settings.dart';
import '../features/settings/controllers/bulk_analysis_settings.dart';
import '../features/settings/controllers/board_display_settings.dart';
import '../features/settings/models/engine_configuration.dart';
import '../features/settings/models/bulk_analysis_configuration.dart';
import '../features/settings/models/board_display_configuration.dart';
import '../infrastructure/settings/preferences_section_storage.dart';

class RuntimeSettings {
  RuntimeSettings({
    required this.engine,
    required this.bulk,
    required this.display,
    required this.databases,
  });
  factory RuntimeSettings.preferences() {
    final maxCores = EngineSettings.systemCores;
    return RuntimeSettings(
      engine: EngineSettings(
        PreferencesSectionStorage(
          keys: {
            ...EngineConfiguration().values.keys,
            'engine_settings.workers',
            'engine_settings.inline_threads',
          },
          decode: (values) {
            if (values['engine_settings.cores'] is! int) {
              final old = [
                values['engine_settings.workers'],
                values['engine_settings.inline_threads'],
              ].whereType<int>();
              if (old.isNotEmpty)
                values['engine_settings.cores'] = old.reduce(
                  (a, b) => a > b ? a : b,
                );
            }
            return EngineConfiguration(values, maxCores);
          },
        ),
      ),
      bulk: BulkAnalysisSettings(
        PreferencesSectionStorage(
          keys: {
            ...BulkAnalysisConfiguration().values.keys,
            BulkAnalysisSettings.legacyPrefKey,
          },
          decode: BulkAnalysisConfiguration.new,
        ),
      ),
      databases: EvalDatabaseSettings(
        PreferencesSectionStorage(
          keys: EvalDatabaseConfiguration().values.keys.toSet(),
          decode: EvalDatabaseConfiguration.new,
        ),
      ),
      display: BoardDisplaySettings(
        PreferencesSectionStorage(
          keys: BoardDisplayConfiguration().values.keys.toSet(),
          decode: BoardDisplayConfiguration.new,
        ),
      ),
    );
  }
  final EngineSettings engine;
  final BulkAnalysisSettings bulk;
  final BoardDisplaySettings display;
  final EvalDatabaseSettings databases;
  Future<void> load() => Future.wait(
    [
      engine.ensureLoaded(),
      bulk.ensureLoaded(),
      display.ensureLoaded(),
      databases.ensureLoaded(),
    ].map((load) => load.catchError((Object _) {})),
  );
  bool _disposed = false;
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    engine.dispose();
    bulk.dispose();
    display.dispose();
    databases.dispose();
  }
}

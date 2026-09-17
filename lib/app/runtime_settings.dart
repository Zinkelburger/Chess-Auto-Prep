import '../features/settings/controllers/engine_settings.dart';
import '../features/settings/controllers/bulk_analysis_settings.dart';
import '../features/settings/controllers/board_display_settings.dart';
import '../features/settings/models/engine_configuration.dart';
import '../features/settings/models/bulk_analysis_configuration.dart';
import '../features/settings/models/board_display_configuration.dart';
import '../infrastructure/settings/preferences_section_storage.dart';
import '../services/engine/board_engine.dart';
import '../services/engine/stockfish_pool.dart';
import '../services/engine/engine_search_budget.dart';

class RuntimeSettings {
  RuntimeSettings({
    required this.engine,
    required this.bulk,
    required this.display,
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
  Future<void> load() => Future.wait(
    [
      engine.ensureLoaded(),
      bulk.ensureLoaded(),
      display.ensureLoaded(),
    ].map((load) => load.catchError((Object _) {})),
  );
  void bindLegacyEngines() {
    BoardEngine.instance.bindSettings(() => engine.committed);
    StockfishPool.instance.bindSettings(() => engine.committed);
    EngineSearchBudget.instance.capacity = () => engine.committed.cores;
  }

  void dispose() {
    engine.dispose();
    bulk.dispose();
    display.dispose();
  }
}

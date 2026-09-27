import 'package:chess_auto_prep/features/settings/controllers/eval_database_settings.dart';
import 'package:chess_auto_prep/features/settings/models/eval_database_configuration.dart';
import 'package:chess_auto_prep/services/eval/cdb_snapshot_download.dart';
import 'package:chess_auto_prep/services/eval/lichess_eval_controller.dart';
import 'package:chess_auto_prep/app/engine_runtime.dart';
import 'package:chess_auto_prep/services/engine/stockfish_pool.dart';
import 'package:chess_auto_prep/services/engine/board_engine.dart';
import 'package:chess_auto_prep/services/engine/engine_lifecycle.dart';
import 'package:chess_auto_prep/services/engine/engine_search_budget.dart';
import 'package:chess_auto_prep/services/engine/generation_lease.dart';
import 'package:chess_auto_prep/services/engine/stockfish_connection_factory.dart';
import 'scripted_engine.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:chess_auto_prep/features/settings/controllers/board_display_settings.dart';
import 'package:chess_auto_prep/app/runtime_settings.dart';
import 'package:chess_auto_prep/features/settings/controllers/engine_settings.dart';
import 'package:chess_auto_prep/features/settings/controllers/bulk_analysis_settings.dart';
import 'package:chess_auto_prep/features/settings/models/engine_configuration.dart';
import 'package:chess_auto_prep/features/settings/models/bulk_analysis_configuration.dart';
import 'package:chess_auto_prep/features/settings/models/board_display_configuration.dart';
import 'package:chess_auto_prep/features/settings/models/section_configuration.dart';
import 'package:chess_auto_prep/features/settings/repositories/settings_section_storage.dart';

class MemorySettingsSection<C extends SectionConfiguration<C>>
    implements SettingsSectionStorage<C> {
  MemorySettingsSection(this.value);
  C value;
  Object? failure;
  Future<void>? readGate;
  Future<void>? writeGate;
  final List<SettingsPatch<C>> writes = [];
  @override
  Future<C> read() async {
    await readGate;
    return value;
  }

  @override
  Future<void> write(SettingsPatch<C> patch) async {
    writes.add(patch);
    await writeGate;
    if (failure != null) throw failure!;
    value = patch.apply(value);
  }
}

RuntimeSettings testRuntimeSettings({Map<String, Object?> values = const {}}) =>
    RuntimeSettings(
      engine: EngineSettings(
        MemorySettingsSection(
          EngineConfiguration(values, EngineSettings.systemCores),
        ),
      ),
      bulk: BulkAnalysisSettings(
        MemorySettingsSection(BulkAnalysisConfiguration(values)),
      ),
      databases: EvalDatabaseSettings(
        MemorySettingsSection(EvalDatabaseConfiguration(values)),
      ),
      display: BoardDisplaySettings(
        MemorySettingsSection(BoardDisplayConfiguration(values)),
      ),
    );

Future<void> pumpRuntimeWidget(
  WidgetTester tester,
  RuntimeSettings settings,
  Widget child,
) async {
  await settings.load();
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        Provider<StockfishPool>.value(value: testEngines(settings).pool),
        Provider<BoardEngine>.value(value: testEngines(settings).board),
        Provider<EngineSearchBudget>.value(value: testEngines(settings).budget),
        Provider<GenerationLease>.value(value: testEngines(settings).lease),
        ChangeNotifierProvider<EngineLifecycle>.value(
          value: testEngines(settings).lifecycle,
        ),
        ChangeNotifierProvider<EvalDatabaseSettings>.value(
          value: settings.databases,
        ),
        ChangeNotifierProvider(
          create: (_) =>
              CdbSnapshotDownloadController(settings: settings.databases),
        ),
        ChangeNotifierProvider(
          create: (_) => LichessEvalController(settings: settings.databases),
        ),
        ChangeNotifierProvider<EngineSettings>.value(value: settings.engine),
        ChangeNotifierProvider<BulkAnalysisSettings>.value(
          value: settings.bulk,
        ),
        ChangeNotifierProvider<BoardDisplaySettings>.value(
          value: settings.display,
        ),
      ],
      child: child,
    ),
  );
}

final _engineRuntimes = Expando<EngineRuntime>();
EngineRuntime testEngines(RuntimeSettings settings) =>
    _engineRuntimes[settings] ??= _createEngines(settings);
EngineRuntime _createEngines(RuntimeSettings settings) {
  final runtime = EngineRuntime(
    settings: settings.engine,
    createConnection:
        StockfishConnectionFactory.createForTest ??
        (() async => ScriptedEngine()),
  );
  addTearDown(runtime.dispose);
  return runtime;
}

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:chess_auto_prep/features/settings/widgets/display_settings_scope.dart';
import 'package:chess_auto_prep/app/runtime_settings.dart';
import 'package:chess_auto_prep/features/settings/controllers/engine_settings.dart';
import 'package:chess_auto_prep/features/settings/controllers/bulk_analysis_settings.dart';
import 'package:chess_auto_prep/features/settings/controllers/board_display_settings.dart';
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
        ChangeNotifierProvider<EngineSettings>.value(value: settings.engine),
        ChangeNotifierProvider<BulkAnalysisSettings>.value(
          value: settings.bulk,
        ),
        ChangeNotifierProvider<BoardDisplaySettings>.value(
          value: settings.display,
        ),
      ],
      child: DisplaySettingsScope(settings: settings.display, child: child),
    ),
  );
}

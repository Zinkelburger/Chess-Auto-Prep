import '../models/bulk_analysis_configuration.dart';
import '../repositories/settings_section_storage.dart';
import 'section_settings_owner.dart';

class BulkAnalysisSettings
    extends SectionSettingsOwner<BulkAnalysisConfiguration> {
  BulkAnalysisSettings(
    SettingsSectionStorage<BulkAnalysisConfiguration> storage,
  ) : super(storage, BulkAnalysisConfiguration());
  static const prefKey = 'engine_settings.bulk_depth';
  static const legacyPrefKey = 'tactics_import.depth';
  static const defaultDepth = BulkAnalysisConfiguration.defaultDepth;
  static const minDepth = BulkAnalysisConfiguration.minDepth;
  static const maxDepth = BulkAnalysisConfiguration.maxDepth;
  int get depth => committed.depth;
  bool get isLoaded => state.committed != null;
  Future<void> setDepth(int value) =>
      edit({prefKey: value.clamp(minDepth, maxDepth)});
}

import 'section_configuration.dart';

class BulkAnalysisConfiguration
    extends ImmutableSection<BulkAnalysisConfiguration> {
  BulkAnalysisConfiguration([Map<String, Object?> input = const {}])
    : super({
        'engine_settings.bulk_depth':
            (input['engine_settings.bulk_depth'] is int
                    ? input['engine_settings.bulk_depth'] as int
                    : input['tactics_import.depth'] is int
                    ? input['tactics_import.depth'] as int
                    : defaultDepth)
                .clamp(minDepth, maxDepth),
      });
  static const defaultDepth = 15;
  static const minDepth = 1;
  static const maxDepth = 99;
  @override
  BulkAnalysisConfiguration withValues(Map<String, Object?> values) =>
      BulkAnalysisConfiguration(values);
  int get depth => values['engine_settings.bulk_depth'] as int;
}

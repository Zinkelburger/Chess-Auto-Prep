/// Configuration for a repertoire coverage run.
///
/// Lives in the feature's model layer (not the config dialog) so that
/// core controllers can depend on it without importing widgets.
library;

import 'package:chess_auto_prep/features/coverage/services/coverage_service.dart';

class CoverageConfig {
  final double targetPercent;
  final LichessDatabase database;
  final Set<String> selectedRatings;
  final Set<String> selectedSpeeds;
  final bool useMaia;
  final int maiaElo;

  const CoverageConfig({
    required this.targetPercent,
    required this.database,
    required this.selectedRatings,
    required this.selectedSpeeds,
    required this.useMaia,
    required this.maiaElo,
  });

  String get ratingsString => (selectedRatings.toList()..sort()).join(',');
  String get speedsString => selectedSpeeds.join(',');
}

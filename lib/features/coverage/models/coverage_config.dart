/// Configuration for a repertoire coverage run.
///
/// Lives in the feature's model layer (not the config dialog) so that
/// core controllers can depend on it without importing widgets.
library;

class CoverageConfig {
  final double targetPercent;

  /// Fall back to Maia for opponent replies the master book has never seen.
  final bool useMaia;
  final int maiaElo;

  const CoverageConfig({
    required this.targetPercent,
    required this.useMaia,
    required this.maiaElo,
  });
}

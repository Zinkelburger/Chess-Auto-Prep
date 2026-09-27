import '../../../models/pgn_filter_models.dart';

/// The accepted filter, separate from a request still being calculated.
class ViewerFilterSelection {
  const ViewerFilterSelection.empty()
    : indices = null,
      config = const SliceConfig.empty(),
      active = false;

  ViewerFilterSelection(List<int> indices, SliceConfig config, int gameCount)
    : indices = List.unmodifiable(indices),
      config = snapshotSliceConfig(config),
      active = !config.isEmpty || indices.length != gameCount;

  final List<int>? indices;
  final SliceConfig config;
  final bool active;
}

SliceConfig snapshotSliceConfig(SliceConfig config) => SliceConfig(
  positionInput: config.positionInput,
  additionalPositions: List.unmodifiable(config.additionalPositions),
  matchAny: config.matchAny,
  headerFilters: List.unmodifiable(config.headerFilters),
  sequencePattern: config.sequencePattern,
  sequenceGap: config.sequenceGap,
);

class SliceRestoreInfo {
  const SliceRestoreInfo({
    required this.filteredCount,
    required this.totalCount,
  });
  final int filteredCount;
  final int totalCount;
}

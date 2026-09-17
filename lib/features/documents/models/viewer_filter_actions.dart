import '../../../models/pgn_filter_models.dart';

/// [config] without the filter that entry [chipIndex] of
/// [SliceConfig.chipLabels] describes, or null when [chipIndex] names no
/// chip. Chips are laid out as the position input, then each non-empty
/// additional position, then the sequence pattern, then each header filter
/// with a value.
SliceConfig? sliceConfigWithoutChip(SliceConfig config, int chipIndex) {
  if (chipIndex < 0 || chipIndex >= config.chipLabels.length) return null;
  final hasPosition = config.positionInput?.isNotEmpty ?? false;
  final hasSequence = config.sequencePattern?.isNotEmpty ?? false;
  final positionSlots = [
    for (final (i, p) in config.additionalPositions.indexed)
      if (p.isNotEmpty) i,
  ];
  final headerSlots = [
    for (final (i, f) in config.headerFilters.indexed)
      if (f.value.isNotEmpty) i,
  ];

  SliceConfig build({
    String? positionInput,
    List<String>? additionalPositions,
    String? sequencePattern,
    List<HeaderFilterConfig>? headerFilters,
  }) => SliceConfig(
    positionInput: positionInput,
    additionalPositions: additionalPositions ?? config.additionalPositions,
    matchAny: config.matchAny,
    headerFilters: headerFilters ?? config.headerFilters,
    sequencePattern: sequencePattern,
    sequenceGap: config.sequenceGap,
  );

  var index = chipIndex;
  if (hasPosition) {
    if (index == 0) {
      return build(sequencePattern: config.sequencePattern);
    }
    index--;
  }
  if (index < positionSlots.length) {
    return build(
      positionInput: config.positionInput,
      additionalPositions: List.of(config.additionalPositions)
        ..removeAt(positionSlots[index]),
      sequencePattern: config.sequencePattern,
    );
  }
  index -= positionSlots.length;
  if (hasSequence) {
    if (index == 0) return build(positionInput: config.positionInput);
    index--;
  }
  return build(
    positionInput: config.positionInput,
    sequencePattern: config.sequencePattern,
    headerFilters: List.of(config.headerFilters)..removeAt(headerSlots[index]),
  );
}

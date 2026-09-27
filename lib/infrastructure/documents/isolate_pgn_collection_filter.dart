import 'dart:isolate';

import '../../models/pgn_filter_models.dart';
import '../../chess_core/pgn/pgn_slice_filter.dart';
import '../../features/documents/repositories/pgn_collection_filter.dart';

class IsolatePgnCollectionFilter implements PgnCollectionFilter {
  const IsolatePgnCollectionFilter();
  @override
  Future<List<int>> match(
    SliceConfig config,
    List<GameRecord> games, {
    Map<String, List<int>>? fenIndex,
  }) => _matchConfig(config, games, fenIndex: fenIndex);
}

Future<List<int>> _matchConfig(
  SliceConfig config,
  List<GameRecord> games, {
  Map<String, List<int>>? fenIndex,
}) {
  final seqPattern = config.sequencePattern;
  return computeSliceMatches(
    games: games,
    targetFen: parseTargetFen(config.positionInput),
    additionalTargetFens: [
      for (final input in config.additionalPositions) ?parseTargetFen(input),
    ],
    matchAny: config.matchAny,
    filters: config.headerFilters
        .map((f) => (field: f.field, mode: f.mode, value: f.value))
        .toList(),
    seqGroups: (seqPattern != null && seqPattern.isNotEmpty)
        ? parseSequenceGroups(seqPattern)
        : const [],
    seqGap: config.sequenceGap,
    fenIndex: fenIndex,
  );
}

/// Compute matching game indices for a combined position / sequence / header
/// filter.  Uses [fenIndex] for O(1) position lookups when available,
/// otherwise falls back to per-game replay in an isolate.
///
/// This is the single entry point shared by `PgnGameFilterWorkspace`,
/// `InlineSliceEditor`, and the injected Viewer filter owner.
Future<List<int>> computeSliceMatches({
  required List<GameRecord> games,
  String? targetFen,
  List<String> additionalTargetFens = const [],
  bool matchAny = false,
  required List<({String field, MatchMode mode, String value})> filters,
  required List<List<String>> seqGroups,
  required int seqGap,
  Map<String, List<int>>? fenIndex,
}) {
  final targets = {?targetFen, ...additionalTargetFens}.toList();
  final filterData = filters
      .map((f) => (field: f.field, modeName: f.mode.name, value: f.value))
      .toList();
  final seqCopy = seqGroups.map((g) => List<String>.from(g)).toList();
  final positionSets = fenIndex == null
      ? null
      : [for (final fen in targets) (fenIndex[fen] ?? const <int>[]).toSet()];
  final hasOtherFilters =
      filters.any((f) => f.value.isNotEmpty) || seqCopy.isNotEmpty;

  // With an index, the position targets narrow the candidates up front — and
  // decide the slice outright when they are the only filter.
  Set<int>? candidates;
  if (positionSets != null &&
      positionSets.isNotEmpty &&
      (!matchAny || !hasOtherFilters)) {
    candidates = Set<int>.of(positionSets.first);
    for (final set in positionSets.skip(1)) {
      candidates = matchAny
          ? (candidates!..addAll(set))
          : candidates!.intersection(set);
    }
    if (!hasOtherFilters) return Future.value(candidates!.toList()..sort());
  }
  final candidateIndices = candidates?.toList()?..sort();
  final gameData = [
    for (final i in candidateIndices ?? List.generate(games.length, (i) => i))
      (
        index: i,
        headers: Map<String, String>.from(games[i].headers),
        pgnText: games[i].pgnText,
      ),
  ];
  return Isolate.run(
    () => matchPgnSliceCandidates(
      gameData: gameData,
      filterData: filterData,
      targets: targets,
      positionSets: positionSets,
      seqCopy: seqCopy,
      seqGap: seqGap,
      matchAny: matchAny,
    ),
  );
}

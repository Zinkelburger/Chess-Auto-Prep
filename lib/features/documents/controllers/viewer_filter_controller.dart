import '../../../models/pgn_filter_models.dart';
import '../../../chess_core/pgn/pgn_slice_filter.dart' show parseTargetFen;
import '../models/viewer_filter_actions.dart';
import '../models/viewer_filter_selection.dart';
import '../repositories/pgn_collection_filter.dart';

/// One owner for accepted filters and pending requests. Each new intent revokes
/// earlier work, including reapplying the same selection or clearing a filter.
class ViewerFilterController {
  ViewerFilterController(this.matcher);
  final PgnCollectionFilter matcher;
  ViewerFilterSelection _selection = const ViewerFilterSelection.empty();
  ViewerFilterSelection get selection => _selection;
  SliceRestoreInfo? _pendingRestore;
  SliceRestoreInfo? get pendingRestore => _pendingRestore;
  Object? _error;
  Object? get error => _error;
  int _revision = 0;
  int _sourceRevision = 0;

  /// Preserve the user's pending intent, but recompute against fresh records
  /// if an edit or opening-header enrichment changes its input mid-flight.
  void sourceChanged() => _sourceRevision++;
  int get revision => _revision;
  bool _loading = false;
  bool get isLoading => _loading;
  bool _disposed = false;
  bool isCurrent(int request) => !_disposed && request == _revision;

  void invalidate() {
    _revision++;
    _loading = false;
    _error = null;
    _pendingRestore = null;
  }

  void clearPendingRestore() => _pendingRestore = null;

  bool apply(List<int> indices, SliceConfig config, int gameCount) {
    if (_disposed) return false;
    _validate(indices, gameCount);
    invalidate();
    return _accept(indices, config, gameCount);
  }

  void reset() {
    if (_disposed) return;
    invalidate();
    _selection = const ViewerFilterSelection.empty();
  }

  /// Restore a previously captured in-memory navigation selection.
  void restoreSelection(ViewerFilterSelection selection) {
    if (_disposed) return;
    invalidate();
    _selection = selection;
  }

  bool isPresetActive(HeaderFilterConfig filter) => _selection
      .config
      .headerFilters
      .any((h) => h.field == filter.field && h.value == filter.value);

  SliceConfig? withoutChip(int index) =>
      sliceConfigWithoutChip(_selection.config, index);

  SliceConfig withPreset(HeaderFilterConfig filter) {
    final config = _selection.config;
    return SliceConfig(
      positionInput: config.positionInput,
      additionalPositions: config.additionalPositions,
      matchAny: config.matchAny,
      headerFilters: [
        for (final header in config.headerFilters)
          if (!((header.field == 'White' || header.field == 'Black') &&
              header.value == filter.value))
            header,
        filter,
      ],
      sequencePattern: config.sequencePattern,
      sequenceGap: config.sequenceGap,
    );
  }

  Future<ViewerFilterSelection?> compute(
    SliceConfig config,
    List<GameRecord> Function() games, {
    Map<String, List<int>>? Function()? fenIndex,
    bool restoring = false,
  }) async {
    if (_disposed) return null;
    invalidate();
    final request = _revision;
    _loading = true;
    try {
      final captured = snapshotSliceConfig(config);
      final targets = <String>{
        ?parseTargetFen(captured.positionInput),
        for (final input in captured.additionalPositions)
          ?parseTargetFen(input),
      };
      while (isCurrent(request)) {
        final source = _sourceRevision;
        final records = List<GameRecord>.unmodifiable([
          for (final game in games())
            (
              headers: Map<String, String>.unmodifiable(game.headers),
              pgnText: game.pgnText,
            ),
        ]);
        // Capture only queried positions, not every entry of a large index.
        final currentIndex = fenIndex?.call();
        final index = currentIndex == null
            ? null
            : Map<String, List<int>>.unmodifiable({
                for (final target in targets)
                  target: List<int>.unmodifiable(
                    currentIndex[target] ?? const [],
                  ),
              });
        List<int> indices;
        try {
          indices = await matcher.match(captured, records, fenIndex: index);
        } catch (_) {
          if (isCurrent(request) && source != _sourceRevision) continue;
          rethrow;
        }
        if (!isCurrent(request)) return null;
        if (source != _sourceRevision) continue;
        _validate(indices, records.length);
        // Saved filters with no matches fall back to the full collection.
        // A deliberate empty search remains valid.
        if (restoring && indices.isEmpty) return null;
        _accept(indices, captured, records.length);
        if (restoring) {
          _pendingRestore = SliceRestoreInfo(
            filteredCount: indices.length,
            totalCount: records.length,
          );
        }
        return _selection;
      }
      return null;
    } catch (error) {
      if (isCurrent(request)) _error = error;
      return null;
    } finally {
      if (isCurrent(request)) _loading = false;
    }
  }

  bool _accept(List<int> indices, SliceConfig config, int count) {
    final current = _selection.indices;
    if (current != null &&
        current.length == indices.length &&
        _selection.active == (!config.isEmpty || indices.length != count) &&
        config.toJsonString() == _selection.config.toJsonString()) {
      var equal = true;
      for (var i = 0; i < indices.length; i++) {
        if (current[i] != indices[i]) {
          equal = false;
          break;
        }
      }
      if (equal) return false;
    }
    _selection = ViewerFilterSelection(indices, config, count);
    return true;
  }

  void _validate(List<int> indices, int count) {
    if (indices.any((i) => i < 0 || i >= count) ||
        indices.toSet().length != indices.length) {
      throw ArgumentError(
        'Filter results must uniquely identify games in the captured collection',
      );
    }
  }

  void dispose() {
    invalidate();
    _disposed = true;
  }
}

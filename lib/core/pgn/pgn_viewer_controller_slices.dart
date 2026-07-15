// Part of pgn_viewer_controller.dart: slice (filter) operations — applying,
// resetting, restoring, persisting, and exporting game slices — plus the
// [SliceRestoreInfo] payload. Same library as the controller, so private
// members resolve across the class/mixin boundary.
part of '../pgn_viewer_controller.dart';

/// Slice operations for [PgnViewerController]. State shared with the rest of
/// the controller is declared abstract here and implemented by the class;
/// fields owned solely by the slice group live in this mixin.
mixin _SliceOps on ChangeNotifier {
  // Implemented by PgnViewerController.
  bool Function() get isActive;
  String? get filePath;
  List<PgnGameEntry> get allGames;
  abstract List<PgnGameEntry> filteredGames;
  abstract bool hasActiveFilters;
  abstract SliceConfig activeSliceConfig;
  abstract int currentGameIndex;
  abstract bool isLoading;
  Map<String, List<int>>? get fenIndex;
  ViewerOpeningTree get _viewerTree;
  bool get showOpeningTree;
  Future<void> loadCurrentGame();
  void applySortMode();
  String buildExportContent();

  List<int>? _activeSliceIndices;

  /// Set when a saved slice is restored on file open so the UI can show a
  /// snackbar; consumed via [clearPendingSliceRestore].
  SliceRestoreInfo? pendingSliceRestore;

  /// Bumped by every synchronous change to the game collection or the active
  /// slice. Async slice operations ([tryRestoreSavedSlice],
  /// [recomputeAndApplyConfig]) capture it before their isolate await and
  /// bail if it moved — otherwise indices computed for the old collection
  /// get applied to (and persisted for) whatever loaded meanwhile.
  int _sliceEpoch = 0;

  Future<void> tryRestoreSavedSlice(
    String path,
    List<PgnGameEntry> entries,
  ) async {
    final epoch = _sliceEpoch;
    final config = await SlicePersistence.load(path);
    if (config == null) return;
    if (!isActive() || epoch != _sliceEpoch) return;

    final allRecords = entries
        .map((g) => (headers: g.headers, pgnText: g.pgnText))
        .toList();
    isLoading = true;
    notifyListeners();

    final indices = await applySliceConfig(
      config,
      allRecords,
      fenIndex: fenIndex,
    );
    // On a stale epoch another load/slice op owns the state now (including
    // isLoading) — touch nothing.
    if (!isActive() || epoch != _sliceEpoch) return;

    isLoading = false;
    // An all-games or zero-game match isn't worth restoring: the former is a
    // no-op, and the latter would blank the viewer for a file that loaded
    // fine (the config likely predates a rewrite of the file).
    if (indices.isEmpty || indices.length == entries.length) {
      notifyListeners();
      return;
    }

    filteredGames = indices.map((i) => allGames[i]).toList();
    hasActiveFilters = true;
    activeSliceConfig = config;
    _activeSliceIndices = List<int>.from(indices);
    currentGameIndex = 0;
    pendingSliceRestore = SliceRestoreInfo(
      filteredCount: filteredGames.length,
      totalCount: allGames.length,
    );
    notifyListeners();
  }

  void clearPendingSliceRestore() => pendingSliceRestore = null;

  void applySlice(List<int> indices, SliceConfig config) {
    if (_activeSliceIndices != null &&
        listEquals(_activeSliceIndices, indices) &&
        config.toJsonString() == activeSliceConfig.toJsonString()) {
      return;
    }
    _sliceEpoch++;
    isLoading = false;
    _activeSliceIndices = List<int>.from(indices);
    filteredGames = indices.map((i) => allGames[i]).toList();
    hasActiveFilters = filteredGames.length != allGames.length;
    activeSliceConfig = config;
    currentGameIndex = 0;
    _viewerTree.clearTree();
    notifyListeners();
    persistSliceConfig(config);
    if (showOpeningTree) _viewerTree.rebuild();
    loadCurrentGame();
  }

  void resetFilters() {
    // Invalidate any in-flight recompute/restore so it can't resurrect the
    // slice being cleared, and take over its loading state.
    _sliceEpoch++;
    isLoading = false;
    filteredGames = List.of(allGames);
    hasActiveFilters = false;
    activeSliceConfig = const SliceConfig.empty();
    _activeSliceIndices = null;
    currentGameIndex = 0;
    _viewerTree.clearTree();
    notifyListeners();
    clearSavedSlice();
    applySortMode();
    if (showOpeningTree) _viewerTree.rebuild();
    loadCurrentGame();
  }

  Future<void> removeSliceChip(int chipIndex) async {
    final labels = activeSliceConfig.chipLabels;
    if (chipIndex < 0 || chipIndex >= labels.length) return;

    final hasPos =
        activeSliceConfig.positionInput != null &&
        activeSliceConfig.positionInput!.isNotEmpty;
    final hasSeq =
        activeSliceConfig.sequencePattern != null &&
        activeSliceConfig.sequencePattern!.isNotEmpty;
    String? newPositionInput = activeSliceConfig.positionInput;
    String? newSequencePattern = activeSliceConfig.sequencePattern;
    int newSequenceGap = activeSliceConfig.sequenceGap;
    final newHeaders = List<HeaderFilterConfig>.from(
      activeSliceConfig.headerFilters,
    );

    int idx = chipIndex;
    if (hasPos && idx == 0) {
      newPositionInput = null;
      idx = -1;
    } else if (hasPos) {
      idx--;
    }

    if (idx >= 0 && hasSeq && idx == 0) {
      newSequencePattern = null;
      idx = -1;
    } else if (hasSeq && idx >= 0) {
      idx--;
    }

    if (idx >= 0) {
      int count = -1;
      for (int i = 0; i < newHeaders.length; i++) {
        if (newHeaders[i].value.isNotEmpty) count++;
        if (count == idx) {
          newHeaders.removeAt(i);
          break;
        }
      }
    }

    final newConfig = SliceConfig(
      positionInput: newPositionInput,
      headerFilters: newHeaders,
      sequencePattern: newSequencePattern,
      sequenceGap: newSequenceGap,
    );

    await recomputeAndApplyConfig(newConfig);
  }

  bool isPresetActive(HeaderFilterConfig filter) => activeSliceConfig
      .headerFilters
      .any((h) => h.field == filter.field && h.value == filter.value);

  /// Apply a preset header filter, replacing any other White/Black filter on
  /// the same player (so "as White" ↔ "as Black" swap rather than stack) while
  /// keeping position/sequence filters.
  Future<void> applySlicePreset(HeaderFilterConfig filter) async {
    final newHeaders =
        activeSliceConfig.headerFilters
            .where(
              (h) =>
                  !((h.field == 'White' || h.field == 'Black') &&
                      h.value == filter.value),
            )
            .toList()
          ..add(filter);
    await recomputeAndApplyConfig(
      SliceConfig(
        positionInput: activeSliceConfig.positionInput,
        headerFilters: newHeaders,
        sequencePattern: activeSliceConfig.sequencePattern,
        sequenceGap: activeSliceConfig.sequenceGap,
      ),
    );
  }

  /// Recompute matches for [newConfig] and apply them (shared by chip removal
  /// and presets).
  Future<void> recomputeAndApplyConfig(SliceConfig newConfig) async {
    if (newConfig.isEmpty) {
      resetFilters();
      return;
    }

    final epoch = _sliceEpoch;
    final allRecords = allGames
        .map((g) => (headers: g.headers, pgnText: g.pgnText))
        .toList();
    isLoading = true;
    notifyListeners();

    final indices = await applySliceConfig(
      newConfig,
      allRecords,
      fenIndex: fenIndex,
    );
    // On a stale epoch another load/slice op owns the state now (including
    // isLoading) — applying would map old-collection indices onto the new
    // games and persist the old config under the new file.
    if (!isActive() || epoch != _sliceEpoch) return;

    isLoading = false;
    notifyListeners(); // applySlice may early-return on identical config
    applySlice(indices, newConfig);
  }

  Future<void> persistSliceConfig(SliceConfig config) async {
    if (filePath == null) return;
    await SlicePersistence.save(filePath!, config);
  }

  Future<void> clearSavedSlice() async {
    if (filePath == null) return;
    await SlicePersistence.clear(filePath!);
  }

  Future<String?> exportSliceToPath(String outPath) async {
    if (filteredGames.isEmpty || filePath == null) return null;
    final savePath = outPath.endsWith('.pgn') ? outPath : '$outPath.pgn';
    try {
      await StorageFactory.instance.writeFile(savePath, buildExportContent());
      return savePath;
    } catch (e) {
      debugPrint('Export failed: $e');
      return null;
    }
  }
}

/// Set when a saved slice is restored so the UI can show a snackbar.
class SliceRestoreInfo {
  final int filteredCount;
  final int totalCount;

  const SliceRestoreInfo({
    required this.filteredCount,
    required this.totalCount,
  });
}

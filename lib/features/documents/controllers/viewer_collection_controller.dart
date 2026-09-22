import 'package:dartchess/dartchess.dart';
import '../../../chess_core/pgn/pgn_collection_players.dart';
import '../../../models/opening_tree.dart' show WdlPerspective;
import '../../../chess_core/pgn/pgn_game_sorting.dart';
import '../../../models/pgn_filter_models.dart';
import '../../../models/pgn_game_entry.dart';

/// Owns collection membership, visible order and selection. Published lists
/// cannot be reordered or resized. Entries still belong to the legacy editor;
/// these lists are membership views, not immutable snapshots of game contents.
class ViewerCollectionController {
  int _contentRevision = 0;
  int get contentRevision => _contentRevision;
  void markContentChanged() => _contentRevision++;

  /// Surname of the player the loaded collection is about (null when mixed).
  /// Drives the one-click "«Player» as White/Black" slice presets.
  String? sliceProtagonist;

  /// When the whole file has the protagonist on one side only ("all Kasparov
  /// black games"), that side; null when they play both colors.
  Side? protagonistFixedSide;

  /// Coloring for tree win/draw/loss stats: player-POV green/red when we know
  /// whose games the current slice shows, neutral white/black otherwise.
  WdlPerspective wdlPerspective(SliceConfig config) {
    final p = sliceProtagonist;
    if (p != null) {
      for (final h in config.headerFilters) {
        if (h.value != p || h.mode == MatchMode.notContains) continue;
        if (h.field == 'White') return WdlPerspective.playerIsWhite;
        if (h.field == 'Black') return WdlPerspective.playerIsBlack;
      }
      if (protagonistFixedSide == Side.white) {
        return WdlPerspective.playerIsWhite;
      }
      if (protagonistFixedSide == Side.black) {
        return WdlPerspective.playerIsBlack;
      }
    }
    return WdlPerspective.whiteBlack;
  }

  void _detectProtagonist(List<PgnGameEntry> entries) {
    sliceProtagonist = detectFileProtagonist(entries);
    protagonistFixedSide = null;
    final p = sliceProtagonist;
    if (p == null) return;
    var asWhite = 0, asBlack = 0;
    for (final g in entries) {
      if ((g.headers['White'] ?? '').split(',').first.trim() == p) asWhite++;
      if ((g.headers['Black'] ?? '').split(',').first.trim() == p) asBlack++;
    }
    if (asWhite > 0 && asBlack == 0) protagonistFixedSide = Side.white;
    if (asBlack > 0 && asWhite == 0) protagonistFixedSide = Side.black;
  }

  int? _collectionPlayerRevision;
  List<PgnGameEntry>? _collectionPlayerSource;
  String? _collectionPlayer;

  /// Shared by Filter and Tree; based on the complete, unfiltered collection.
  String? get collectionPlayer {
    if (_collectionPlayerRevision != contentRevision ||
        !identical(_collectionPlayerSource, games)) {
      _collectionPlayerRevision = contentRevision;
      _collectionPlayerSource = games;
      _collectionPlayer = detectSingleCollectionPlayer(games);
    }
    return _collectionPlayer;
  }

  String? detectProtagonist() => detectProtagonistFrom(games);

  /// Returns both player names when all games are between the same two players.
  ({String player1, String player2})? detectBothPlayers() =>
      detectBothPlayersFrom(games);

  /// One-click slice presets derived from [sliceProtagonist].
  ///
  /// [shortLabel] is for the app bar, where two chips repeating a long
  /// username push each other off the edge of a bar that only scrolls if you
  /// know it does; the full [label] stays in the slice dialog and in the
  /// chip's tooltip.
  List<({String label, String shortLabel, HeaderFilterConfig filter})>
  get slicePresets {
    final p = sliceProtagonist;
    if (p == null) return const [];
    return [
      (
        label: '$p as White',
        shortLabel: 'as White',
        filter: HeaderFilterConfig(
          field: 'White',
          mode: MatchMode.contains,
          value: p,
        ),
      ),
      (
        label: '$p as Black',
        shortLabel: 'as Black',
        filter: HeaderFilterConfig(
          field: 'Black',
          mode: MatchMode.contains,
          value: p,
        ),
      ),
    ];
  }

  List<PgnGameEntry> _games = const [];
  Set<PgnGameEntry> _members = Set.identity();
  List<PgnGameEntry> _visible = const [];
  List<int> _indices = const [];
  int _selected = 0;
  GameSortMode _sort = GameSortMode.fileOrder;
  int _revision = 0;
  int _selectionRevision = 0;

  List<PgnGameEntry> get games => _games;
  List<PgnGameEntry> get visibleGames => _visible;
  List<int> get visibleIndices => _indices;
  int get selectedIndex => _selected;
  PgnGameEntry? get selectedGame =>
      _visible.isEmpty ? null : _visible[_selected];
  GameSortMode get sortMode => _sort;
  int get viewRevision => _revision;

  /// Every accepted navigation intent, even when it selects the same row.
  /// Async selection work uses this token; presentation equality uses viewRevision.
  int get selectionRevision => _selectionRevision;
  bool containsGame(PgnGameEntry game) => _members.contains(game);

  /// Captures membership once. Caller-owned list changes cannot alter this
  /// collection or invalidate filter indices behind the owner's back.
  void adopt(Iterable<PgnGameEntry> games) {
    _games = List.unmodifiable(games);
    _detectProtagonist(_games);
    _members = Set.identity()..addAll(_games);
    _replaceOrder(
      List.generate(_games.length, (index) => index),
      sortMode: GameSortMode.fileOrder,
      force: true,
    );
  }

  void applyFilter(List<int> indices) {
    _validate(indices);
    _replaceOrder(indices);
  }

  void resetFilter() =>
      _replaceOrder(List.generate(_games.length, (index) => index));

  /// Restores exactly the captured order. Validation is atomic, including the
  /// selected index; a malformed bookmark cannot leave a half-restored view.
  void restoreView({
    required List<int> indices,
    required int selectedIndex,
    required GameSortMode sortMode,
  }) {
    _validate(indices);
    if (indices.isEmpty
        ? selectedIndex != 0
        : selectedIndex < 0 || selectedIndex >= indices.length) {
      throw RangeError.value(selectedIndex, 'selectedIndex');
    }
    _replaceOrder(indices, selectedIndex: selectedIndex, sortMode: sortMode);
  }

  bool select(int index) {
    if (index < 0 || index >= _visible.length) return false;
    _selectionRevision++;
    if (_selected != index) {
      _selected = index;
      _revision++;
    }
    return true;
  }

  /// Equal sort keys keep file order, so sorting is deterministic even after
  /// visiting another sort mode. File order always uses original indices.
  void sort(GameSortMode mode, {bool resetSelection = false}) {
    final indices = List<int>.of(_indices);
    int compare(int a, int b) {
      final order = switch (mode) {
        GameSortMode.fileOrder => a.compareTo(b),
        GameSortMode.dateDesc => compareGamesByDateDesc(_games[a], _games[b]),
        GameSortMode.ratingDesc => compareGamesByRatingDesc(
          _games[a],
          _games[b],
        ),
        GameSortMode.ratingAsc => compareGamesByRatingAsc(_games[a], _games[b]),
      };
      return order == 0 ? a.compareTo(b) : order;
    }

    indices.sort(compare);
    _replaceOrder(
      indices,
      selectedIndex: resetSelection ? 0 : _selected,
      sortMode: mode,
    );
  }

  void _validate(List<int> indices) {
    final seen = <int>{};
    for (final index in indices) {
      if (index < 0 || index >= _games.length) {
        throw RangeError.index(index, _games);
      }
      if (!seen.add(index)) {
        throw ArgumentError.value(indices, 'indices', 'Duplicate game index');
      }
    }
  }

  void _replaceOrder(
    List<int> indices, {
    int selectedIndex = 0,
    GameSortMode? sortMode,
    bool force = false,
  }) {
    _selectionRevision++;
    final mode = sortMode ?? _sort;
    final sameOrder =
        indices.length == _indices.length &&
        Iterable<int>.generate(
          indices.length,
        ).every((i) => indices[i] == _indices[i]);
    if (!force && sameOrder && selectedIndex == _selected && mode == _sort) {
      return;
    }
    if (force || !sameOrder) {
      _indices = List.unmodifiable(indices);
      _visible = List.unmodifiable(indices.map((index) => _games[index]));
    }
    _selected = selectedIndex;
    _sort = mode;
    _revision++;
  }
}

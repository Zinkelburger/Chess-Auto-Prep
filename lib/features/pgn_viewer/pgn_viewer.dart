import '../../chess/pgn/reading_place.dart';
import '../../storage/viewer_places.dart';
import 'viewer_reading.dart';
import '../../chess/pgn/game_order.dart';
import '../../storage/pgn_export.dart';
import '../../workspace/game_ordering.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../chess/pgn/chapter.dart';
import '../../chess/pgn/chapter_grouping.dart';
import '../../chess/pgn/chapter_line.dart';
import '../../chess/pgn/collection_player.dart';
import '../../chess/pgn/study.dart' show ChapterDraft;
import 'package:dartchess/dartchess.dart' show Side;
import '../../chess/pgn/game_summary.dart';
import '../../chess/pgn/game_text.dart';
import '../../chess/pgn/game_tree.dart' show NodePath;
import '../../storage/chapter_files.dart';
import '../../storage/pending_writes.dart';
import '../../storage/pgn_file_import.dart';
import '../../storage/pgn_file_picker.dart';
import '../../storage/recent_pgn_files.dart';
import '../../storage/settings_store.dart';
import '../../workspace/document_session.dart';
import '../../workspace/file_filter.dart';
import '../../workspace/filter_run.dart' show mainLineSans;

/// The PGN Viewer's own state: the files opened before, which file the
/// viewer has open now, and the search over its games. The list shows the
/// games that pass both the search and the [FileFilter], which the
/// explorer's `This file` reads too.
///
/// The games themselves are not here. A viewed file is the document the
/// workspace has open, one game of it on the board, so the session holds
/// them and switching game is a command over it. This owner knows which
/// file is the viewer's and what to say about each game in the list.
final class PgnViewer extends ChangeNotifier implements GameOrdering {
  PgnViewer({
    required RecentFiles recent,
    this.exporter,
    this.places,
    PendingWrites? pendingWrites,
    required PgnFilePicker picker,
    required PgnFileImport import,
    required SettingsStore settings,
    required DocumentSession session,
    required FileFilter filter,
    required String collections,
  }) : pendingWrites = pendingWrites ?? PendingWrites(),
       _recentFiles = recent,
       _picker = picker,
       _import = import,
       _settings = settings,
       _session = session,
       _filter = filter,
       _collections = collections {
    _session.addListener(_followTheDocument);
    _filter.addListener(_followTheFilter);
    _reading.start();
  }

  /// How many files the list remembers, which is the old app's number.
  static const maxRecent = 10;

  /// How many players the follow box suggests.
  static const maxPlayers = 50;

  final ViewerPlaces? places;
  late final _reading = ViewerReading(
    session: _session,
    filter: _filter,
    pending: pendingWrites,
    store: places,
    activePath: () => file?.path,
    sort: () => _sort,
    setSort: sortBy,
    perspective: () => _perspective,
    changed: notifyListeners,
  );
  Future<ReadingPlace?> savedPlace(ChapterRef ref) => _reading.load(ref.path);
  Future<void> retryReading() => _reading.retry();
  final PgnExport? exporter;
  final PendingWrites pendingWrites;
  final RecentFiles _recentFiles;
  final PgnFilePicker _picker;
  final PgnFileImport _import;
  final SettingsStore _settings;
  final DocumentSession _session;
  final FileFilter _filter;

  /// The `pgn_collections` folder, absolute: where the file dialog starts
  /// when nothing was opened before, and where a copy of a file this app
  /// may not write goes.
  final String _collections;
  String get collections => _collections;

  List<String> _recent = const [];
  String? _recentProblem;
  final _unsavedRecent = <Object, String>{};

  /// Reads and writes of the recent list take turns: the list is shared
  /// with the old app and kept by read, change, write, and two of those
  /// overlapping would each write over what the other added.
  Future<void> _recentTurn = Future.value();
  ChapterRef? _file;
  Chapter? _rowsOf;
  List<ChapterLine>? _rowsLines;
  List<GameSummary> _rows = const [];

  /// Each game's chapter, when the file has chapters; else null.
  List<String>? _chapterOf;
  String _query = '';
  Perspective _perspective = const FollowCollectionPlayer();

  /// The file's player, when one plays in most of its games; worked out
  /// once per list of games.
  String? _collectionPlayer;
  List<String> _players = const [];

  /// The game the board was last turned for, so an edit to it or a move
  /// through it does not undo the user's own flip.
  (ChapterRef?, int?)? _orientedFor;
  GameOrder _sort = GameOrder.fileOrder;
  GameOrder get sort => _sort;
  List<int>? _order;
  Map<int, int>? _ordinals;
  int ordinalOf(int game) =>
      (_ordinals ??= {
        for (final (i, index) in gameOrder.indexed) index: i,
      })[game] ??
      game;
  @override
  List<int> get gameOrder => file == null
      ? List.generate(_session.gameCount ?? 0, (i) => i)
      : _order ??= List.unmodifiable(visible.map((row) => row.$1));

  void sortBy(GameOrder order) {
    if (_sort == order) return;
    _sort = order;
    _reading.capture();
    _selection = null;
    _order = null;
    _ordinals = null;
    notifyListeners();
  }

  void walk(int by) {
    final indexes = gameOrder;
    final current = indexes.indexOf(this.current ?? -1);
    final next = current < 0 ? (by > 0 ? 0 : indexes.length - 1) : current + by;
    if (next >= 0 && next < indexes.length) showGame(indexes[next]);
  }

  /// Capture the visible draft before a picker can change file or selection.
  String? exportText() {
    if (file == null || _filter.busy || _filter.problem != null) return null;
    final chapter = _session.snapshot();
    if (chapter == null || gameOrder.isEmpty) return null;
    return chapter.preamble +
        [
          for (final index in gameOrder) chapter.lines[index].text,
        ].join('\n\n') +
        '\n';
  }

  /// The games the list shows, in its order, as chapters for a study: each
  /// with its own tags, notes and variations, facing the followed player.
  /// A game reading could not take whole is left out rather than cut short.
  List<ChapterDraft> selectionDrafts() {
    final chapter = _session.snapshot();
    if (file == null || chapter == null || _filter.busy) return const [];
    final player = followed;
    return [
      for (final index in gameOrder)
        if (chapter.lines[index] case final line
            when line.isWhole && line.tree != null)
          ChapterDraft(
            name: _rows[index].title,
            orientation:
                (player == null ? null : sideOfPlayer(player, line.tags)) ??
                Side.white,
            moves: line.tree!,
            tags: line.tags,
            result: line.terminator,
          ),
    ];
  }

  Future<PgnExportResult> export(String name, String text) =>
      exporter?.save(name, text) ??
      Future.value(const PgnExportFailed('File export is unavailable.'));

  int _filterSeen = -1;
  ({List<(int, GameSummary)> games, List<ViewerChapter> chapters})? _selection;
  Map<String, int> _chapterSizes = const {};
  bool _disposed = false;

  /// The files opened before, newest first, as absolute paths.
  List<String> get recent => _recent;

  /// A sentence about the recent list when it could not be read or kept,
  /// or null when it could.
  String? get recentProblem => _recentProblem ?? _reading.problem;

  /// The file the viewer opened, while it is still the document on the
  /// board. Null when the workspace has moved on to a chapter or a study,
  /// or when nothing is open.
  ChapterRef? get file => _file == _session.source ? _file : null;

  /// Which game of [file] is on the board.
  int? get current => file == null ? null : _session.game;

  /// One summary per game of [file], in file order.
  List<GameSummary> get games => file == null ? const [] : _rows;

  /// One cached selection feeds both flat and grouped views. A chapter-name
  /// match includes its games, so the empty state and the rows always agree.
  List<(int, GameSummary)> get visible =>
      file == null ? const [] : (_selection ??= _select()).games;

  List<ViewerChapter> get chapters =>
      file == null ? const [] : (_selection ??= _select()).chapters;

  ({List<(int, GameSummary)> games, List<ViewerChapter> chapters}) _select() {
    final needle = _query.trim().toLowerCase();
    final selected = <(int, GameSummary)>[];
    final grouped = <String, List<(int, GameSummary)>>{};
    for (final index in orderGames(
      _rowsLines ?? const [],
      Iterable.generate(_rows.length),
      _sort,
    )) {
      final game = _rows[index];
      if (!_filter.keeps(index)) continue;
      final title = _chapterOf?[index];
      if (needle.isNotEmpty &&
          !game.searchText.contains(needle) &&
          !(title?.toLowerCase().contains(needle) ?? false)) {
        continue;
      }
      final row = (index, game);
      selected.add(row);
      if (title != null) grouped.putIfAbsent(title, () => []).add(row);
    }
    return (
      games: List.unmodifiable(selected),
      chapters: List.unmodifiable([
        for (final MapEntry(key: title, value: games) in grouped.entries)
          ViewerChapter(
            title,
            List.unmodifiable(games),
            size: _chapterSizes[title]!,
          ),
      ]),
    );
  }

  String get query => _query;

  /// The folder of [path] as the user knows it: from their home down when
  /// it is under it, which Documents is, else the whole path.
  String folderShown(String path) {
    final folder = p.dirname(path);
    final home = p.dirname(p.dirname(_collections));
    // Under the file system's root everything is "under home"; that is not
    // a home, and the path is left whole.
    if (p.equals(home, p.rootPrefix(home))) return folder;
    return p.isWithin(home, folder) ? p.relative(folder, from: home) : folder;
  }

  void search(String query) {
    if (query == _query) return;
    _query = query;
    _selection = null;
    _order = null;
    _ordinals = null;
    notifyListeners();
  }

  /// Retries accepted additions before reading the list. Failed additions
  /// remain owned by the registry even when this viewer has been replaced.
  Future<void> loadRecent() async {
    await _reading.retry();
    await pendingWrites.retry(_recentFiles);
    await _inTurn(() async {
      final read = await _recentFiles.load();
      if (_disposed) return;
      final unsaved = pendingWrites.unfinished(_recentFiles).firstOrNull;
      switch (read) {
        case RecentFilesListed(:final paths):
          _showRecent(paths);
          _recentProblem = unsaved?.detail;
        case RecentFilesUnreadable():
          _recentProblem = unsaved?.detail ?? _unreadable;
      }
      notifyListeners();
    });
  }

  /// Asks the desktop for a file, starting beside the open one, else beside
  /// the last one, else in the collections folder, and answers the file to
  /// open for it. Null when the user closed the dialog without choosing.
  Future<ChapterRef?> browse() async {
    final near = file?.path ?? _recent.firstOrNull;
    final path = await _picker.pickPgn(
      startIn: near == null ? _collections : p.dirname(near),
    );
    if (path == null || _disposed) return null;
    return fileFor(path);
  }

  /// The file to open for [path], whether it came from the dialog or the
  /// recent list: itself when it is inside Documents, otherwise a copy made
  /// in the collections folder, so what goes on the board can be edited and
  /// kept. Null, with [recentProblem] saying why, when no copy could be made.
  /// With copying switched off in the settings the file opens where it is,
  /// to read.
  Future<ChapterRef?> fileFor(String path) =>
      pendingWrites.track(_import, _fileFor(path), label: 'PGN import');

  Future<ChapterRef?> _fileFor(String path) async {
    if (!_settings.value.copyFilesIntoDocuments) return ChapterRef.at(path);
    switch (await _import.insideDocuments(path)) {
      case FileToOpen(path: final inside):
        return ChapterRef.at(inside);
      case ImportFailed(:final detail):
        if (_disposed) return null;
        _recentProblem =
            'Could not copy ${p.basename(path)} into your '
            'Documents: $detail';
        notifyListeners();
        return null;
    }
  }

  /// [ref] is now the viewer's file: it goes to the top of the recent list,
  /// which is then kept. Called once the workspace has it open, so a file
  /// that could not be read is not remembered as one that was.
  Future<void> opened(
    ChapterRef ref, {
    ReadingPlace? place,
    bool Function()? currentRequest,
  }) async {
    _file = ref;
    _sort = GameOrder.fileOrder;
    _perspective = place?.perspective ?? const FollowCollectionPlayer();
    _orientedFor = null;
    _orient();
    _query = '';
    _selection = null;
    _order = null;
    _ordinals = null;
    await _reading.restore(place, currentRequest ?? () => true);
    final intent = Object();
    _unsavedRecent[intent] = ref.path;
    _recent = _first(ref.path, _recent);
    notifyListeners();
    final accepted = pendingWrites.accept<String?>(
      resource: _recentFiles,
      label: 'Recent files',
      work: () => _inTurn(() => _remember(intent, ref.path)),
      problem: (detail) => detail,
      blocked: () => _recentProblem ?? 'An earlier recent file was not saved.',
    );
    return accepted.run().then<void>((_) {});
  }

  /// Applies the accepted prepend to the latest persisted list. Disposal only
  /// stops notifications: it cannot abandon the accepted write or its result.
  /// Retrying a prepend is idempotent, including a lost save acknowledgement.
  Future<String?> _remember(Object intent, String path) async {
    try {
      switch (await _recentFiles.load()) {
        case RecentFilesUnreadable():
          _recentProblem = _unreadable;
        case RecentFilesListed(:final paths):
          final next = _first(path, paths);
          _showRecent(next);
          if (await _recentFiles.save(next)) {
            _unsavedRecent.remove(intent);
            _recentProblem = null;
          } else {
            _recentProblem = 'The recent files list was not saved.';
          }
      }
    } on Object catch (error) {
      _recentProblem = 'The recent files list was not saved: $error';
    }
    if (!_disposed) notifyListeners();
    return _recentProblem;
  }

  /// Keep accepted, unsaved additions visible across ordinary list refreshes.
  void _showRecent(List<String> paths) {
    _recent = List.unmodifiable(paths);
    for (final path in _unsavedRecent.values) {
      _recent = _first(path, _recent);
    }
  }

  /// Reads and writes take turns. Only accepted mutations enter PendingWrites;
  /// a successful read must never acknowledge an earlier failed write.
  Future<T> _inTurn<T>(Future<T> Function() job) {
    final run = _recentTurn.then((_) => job());
    _recentTurn = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  static const _unreadable = 'The recent files could not be read.';

  /// [paths] with [path] at the top, once, as many as the list keeps.
  static List<String> _first(String path, List<String> paths) =>
      List.unmodifiable(
        [path, ...paths.where((other) => other != path)].take(maxRecent),
      );

  /// The viewer's file was closed, so the list of games goes with it.
  void closed() {
    _file = null;
    _query = '';
    _selection = null;
    _order = null;
    _ordinals = null;
    notifyListeners();
  }

  /// Puts game [index] on the board where the filter found it: at the
  /// position it searched for, or after the moves it asked for.
  void showGame(int index) {
    _session.showGame(index);
    final applied = _filter.applied;
    if (applied.position case final position?) {
      if (_session.tree?.mainLineTo(position) case final path?)
        _session.goTo(path);
    } else if (applied.readsMoves) {
      if (applied.reachIn(mainLineSans(_session.tree)) case final plies?)
        _session.goTo(NodePath.of(List.filled(plies, 0)));
    }
  }

  /// The rows follow the document. A new chapter value is told to the
  /// list, which shows which game is on the board; the games are
  /// summarised again, once for every reader, only when the chapter holds
  /// another list of them, which a move to another game of the file need
  /// not.
  void _followTheDocument() {
    final chapter = _session.chapter;
    if (identical(chapter, _rowsOf)) return;
    _rowsOf = chapter;
    final lines = chapter?.lines;
    if (!identical(lines, _rowsLines)) {
      _rowsLines = lines;
      _summarise(lines ?? const []);
    }
    _orient();
    notifyListeners();
  }

  /// Whose side the games are shown from.
  Perspective get perspective => _perspective;

  /// The player the board follows now, or null for none: the one chosen,
  /// else the file's own player unless the user chose nobody.
  String? get followed => switch (_perspective) {
    FollowPlayer(:final name) => name,
    FollowNobody() => null,
    FollowCollectionPlayer() => _collectionPlayer,
  };

  /// The file's players, those in the most games first: what the follow
  /// box suggests.
  List<String> get players => file == null ? const [] : _players;

  /// The side the followed player had in the game at [index] of the file
  /// and who they played, or null when nobody is followed or they are not
  /// one of its two players: what a row of their collection says instead
  /// of repeating their name.
  ({Side side, String opponent})? followedIn(int index) {
    final player = followed;
    final lines = _rowsLines;
    if (file == null || player == null || lines == null) return null;
    if (index >= lines.length) return null;
    final tags = lines[index].tags;
    final side = sideOfPlayer(player, tags);
    if (side == null) return null;
    final opponent = tagValue(
      tags,
      side == Side.white ? 'Black' : 'White',
    )?.trim();
    if (opponent == null || opponent.isEmpty || opponent == '?') return null;
    return (side: side, opponent: opponent);
  }

  /// How many of the file's games the followed player had White in and how
  /// many Black, worked out once per player and list of games.
  ({int white, int black}) get followedSides {
    final player = followed;
    final lines = _rowsLines;
    if (file == null || player == null || lines == null) {
      return (white: 0, black: 0);
    }
    final known = _sides;
    if (known != null &&
        known.player == player &&
        identical(known.lines, lines)) {
      return known.count;
    }
    var white = 0, black = 0;
    for (final line in lines) {
      switch (sideOfPlayer(player, line.tags)) {
        case Side.white:
          white++;
        case Side.black:
          black++;
        case null:
      }
    }
    final count = (white: white, black: black);
    _sides = (player: player, lines: lines, count: count);
    return count;
  }

  ({String player, List<ChapterLine> lines, ({int white, int black}) count})?
  _sides;

  /// Follows the player [typed] names from now on, or nobody when it is
  /// empty; the game on the board turns at once. Called with a name picked
  /// or submitted, never one half typed.
  void follow(String typed) {
    final name = typed.trim();
    final next = name.isEmpty ? const FollowNobody() : FollowPlayer(name);
    if (next == _perspective) return;
    _perspective = next;
    _orientedFor = null;
    // Following nobody gives the board back its own way round.
    if (next is FollowNobody && _session.flipped) _session.flip();
    _orient();
    _reading.capture();
    notifyListeners();
  }

  /// Turns the board to the followed player's side of the game on it, once
  /// per game: a flip the user makes afterwards stands.
  void _orient() {
    final lines = _session.chapter?.lines;
    final game = current;
    final key = (file, game);
    if (key == _orientedFor) return;
    _orientedFor = key;
    final player = followed;
    if (player == null || lines == null || game == null) return;
    if (game >= lines.length) return;
    final side = sideOfPlayer(player, lines[game].tags);
    if (side != null && _session.orientation != side) _session.flip();
  }

  /// What the list says about each list of games, by that very list: a
  /// file gone back to with its games unchanged — another tab and back —
  /// is not summarised again, which for ten thousand games is most of
  /// what putting it back up costs.
  static final _listings = Expando<_Listing>('game listing');

  void _summarise(List<ChapterLine> lines) {
    final listing = _listings[lines] ??= _Listing.of(lines);
    _collectionPlayer = listing.player;
    _players = listing.players;
    _chapterOf = listing.chapterOf;
    _chapterSizes = listing.chapterSizes;
    _rows = listing.rows;
    _selection = null;
    _order = null;
    _ordinals = null;
  }

  /// The filter applied: the list is another list.
  void _followTheFilter() {
    if (_filter.revision == _filterSeen) return;
    _filterSeen = _filter.revision;
    _selection = null;
    _order = null;
    _ordinals = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _reading.dispose();
    _session.removeListener(_followTheDocument);
    _filter.removeListener(_followTheFilter);
    super.dispose();
  }
}

/// One chapter of the viewed file: its title and the games in it that match
/// the search, each with its place in the file.
final class ViewerChapter {
  const ViewerChapter(this.title, this.games, {required this.size});

  final String title;
  final List<(int, GameSummary)> games;

  /// How many games the chapter holds, whatever the search shows of it.
  final int size;
}

/// What the viewer's list says about one list of games: each game's row,
/// the chapters they fall under and the players they are by.
final class _Listing {
  _Listing._({
    required this.player,
    required this.players,
    required this.chapterOf,
    required this.chapterSizes,
    required this.rows,
  });

  factory _Listing.of(List<ChapterLine> lines) {
    final tags = [for (final line in lines) line.tags];
    final grouping = groupChapters(tags);
    final chapterOf = grouping.hasChapters ? grouping.titles : null;
    final sizes = <String, int>{};
    for (final title in chapterOf ?? const <String>[]) {
      sizes[title] = (sizes[title] ?? 0) + 1;
    }
    return _Listing._(
      player: collectionPlayer(tags),
      players: List.unmodifiable(
        playerCounts(tags).keys.take(PgnViewer.maxPlayers),
      ),
      chapterOf: chapterOf,
      chapterSizes: sizes,
      rows: List.unmodifiable([
        for (final (index, line) in lines.indexed)
          _summary(line, index, grouping),
      ]),
    );
  }

  /// The file's player, when one plays in most of its games.
  final String? player;

  /// The file's players, those in the most games first.
  final List<String> players;

  /// Each game's chapter, when the file has chapters; else null.
  final List<String>? chapterOf;
  final Map<String, int> chapterSizes;

  /// One summary per game, in file order.
  final List<GameSummary> rows;

  /// A game's row. Under a chapter a course's line is called by its own
  /// title — the header [ChapterGrouping.titleKey] names — rather than
  /// `Chapter – Line` as its player tags would read.
  static GameSummary _summary(
    ChapterLine line,
    int index,
    ChapterGrouping grouping,
  ) {
    final game = summarizeGame(line, index: index);
    if (!grouping.hasChapters) return game;
    final title = tagValue(line.tags, grouping.titleKey)?.trim() ?? '';
    if (isPlaceholderTitle(title) ||
        title == grouping.titles[index] ||
        !game.title.contains(grouping.titles[index])) {
      return game;
    }
    return GameSummary(
      title: title,
      result: game.result,
      setting: game.setting,
    );
  }
}

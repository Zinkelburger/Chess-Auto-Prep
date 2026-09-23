import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../chess/game_filter.dart';
import '../../chess/pgn/chapter.dart';
import '../../chess/pgn/chapter_grouping.dart';
import '../../chess/pgn/chapter_line.dart';
import '../../chess/pgn/game_summary.dart';
import '../../chess/pgn/game_text.dart';
import '../../storage/chapter_files.dart';
import '../../storage/pgn_file_import.dart';
import '../../storage/pgn_file_picker.dart';
import '../../storage/recent_pgn_files.dart';
import '../../storage/settings_store.dart';
import '../../workspace/document_session.dart';
import '../../workspace/file_filter.dart';

/// The PGN Viewer's own state: the files opened before, which file the
/// viewer has open now, and the search over its games. The list shows the
/// games that pass both the search and the [FileFilter], which the
/// explorer's `This file` reads too.
///
/// The games themselves are not here. A viewed file is the document the
/// workspace has open, one game of it on the board, so the session holds
/// them and switching game is a command over it. This owner knows which
/// file is the viewer's and what to say about each game in the list.
final class PgnViewer extends ChangeNotifier {
  PgnViewer({
    required RecentFiles recent,
    required PgnFilePicker picker,
    required PgnFileImport import,
    required SettingsStore settings,
    required DocumentSession session,
    required FileFilter filter,
    required String collections,
  }) : _recentFiles = recent,
       _picker = picker,
       _import = import,
       _settings = settings,
       _session = session,
       _filter = filter,
       _collections = collections {
    _session.addListener(_followTheDocument);
    _filter.addListener(_followTheFilter);
  }

  /// How many files the list remembers, which is the old app's number.
  static const maxRecent = 10;

  final RecentFiles _recentFiles;
  final PgnFilePicker _picker;
  final PgnFileImport _import;
  final SettingsStore _settings;
  final DocumentSession _session;
  final FileFilter _filter;

  /// The `pgn_collections` folder, absolute: where the file dialog starts
  /// when nothing was opened before.
  final String _collections;

  List<String> _recent = const [];
  String? _recentProblem;

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
  GameFilter _filterSeen = GameFilter.none;
  bool _disposed = false;

  /// The files opened before, newest first, as absolute paths.
  List<String> get recent => _recent;

  /// A sentence about the recent list when it could not be read or kept,
  /// or null when it could.
  String? get recentProblem => _recentProblem;

  /// The file the viewer opened, while it is still the document on the
  /// board. Null when the workspace has moved on to a chapter or a study,
  /// or when nothing is open.
  ChapterRef? get file => _file == _session.source ? _file : null;

  /// Which game of [file] is on the board.
  int? get current => file == null ? null : _session.game;

  /// One summary per game of [file], in file order.
  List<GameSummary> get games => file == null ? const [] : _rows;

  /// The games that pass the filter and whose players, result or event
  /// match the search, paired with their place in the file, which is what
  /// opening one needs.
  List<(int, GameSummary)> get visible {
    final needle = _query.trim().toLowerCase();
    return [
      for (final (index, game) in games.indexed)
        if (_filter.keeps(index) &&
            (needle.isEmpty || game.searchText.contains(needle)))
          (index, game),
    ];
  }

  /// The games that match the search under their chapters, in the order
  /// the chapters first appear: a study or a course read as the builder
  /// reads it. Empty when the file has no chapters, and the list is flat.
  List<ViewerChapter> get chapters {
    final of = _chapterOf;
    if (file == null || of == null) return const [];
    final needle = _query.trim().toLowerCase();
    final grouped = <String, List<(int, GameSummary)>>{};
    final sizes = <String, int>{};
    for (final (index, game) in games.indexed) {
      final title = of[index];
      sizes[title] = (sizes[title] ?? 0) + 1;
      final inChapter = grouped.putIfAbsent(title, () => []);
      final found =
          needle.isEmpty ||
          game.searchText.contains(needle) ||
          title.toLowerCase().contains(needle);
      if (found && _filter.keeps(index)) inChapter.add((index, game));
    }
    return [
      for (final MapEntry(key: title, value: games) in grouped.entries)
        if (games.isNotEmpty)
          ViewerChapter(title, games, size: sizes[title] ?? games.length),
    ];
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
    notifyListeners();
  }

  /// Reads the recent list again, after any read or write already asked for.
  Future<void> loadRecent() => _inTurn(() async {
    final read = await _recentFiles.load();
    if (_disposed) return;
    switch (read) {
      case RecentFilesListed(:final paths):
        _recent = List.unmodifiable(paths);
        _recentProblem = null;
      case RecentFilesUnreadable():
        _recentProblem = _unreadable;
    }
    notifyListeners();
  });

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
  Future<ChapterRef?> fileFor(String path) async {
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
  Future<void> opened(ChapterRef ref) {
    _file = ref;
    _query = '';
    _recent = _first(ref.path, _recent);
    notifyListeners();
    return _inTurn(() => _remember(ref.path));
  }

  /// Puts [path] first in the list as it is kept now, not as this viewer
  /// last read it: the viewer may not have read it at all — the list
  /// column hidden, or its read still on the way — and writing what is on
  /// screen would replace the old app's list with one file. A list that
  /// cannot be read is left as it is.
  Future<void> _remember(String path) async {
    final read = await _recentFiles.load();
    if (_disposed) return;
    switch (read) {
      case RecentFilesUnreadable():
        _recentProblem = _unreadable;
        notifyListeners();
        return;
      case RecentFilesListed(:final paths):
        _recent = _first(path, paths);
        notifyListeners();
    }
    final kept = await _recentFiles.save(_recent);
    if (_disposed) return;
    _recentProblem = kept ? null : 'The recent files list was not saved.';
    notifyListeners();
  }

  /// Runs [job] after every read and write of the recent list asked for
  /// before it. A job that fails still answers its caller with the error
  /// and leaves the turn to the next.
  Future<void> _inTurn(Future<void> Function() job) {
    final run = _recentTurn.then((_) => job());
    _recentTurn = run.then((_) {}, onError: (Object _) {});
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
    notifyListeners();
  }

  void showGame(int index) => _session.showGame(index);

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
    notifyListeners();
  }

  void _summarise(List<ChapterLine> lines) {
    final grouping = groupChapters([for (final line in lines) line.tags]);
    _chapterOf = grouping.hasChapters ? grouping.titles : null;
    _rows = List.unmodifiable([
      for (final (index, line) in lines.indexed)
        _summary(line, index, grouping),
    ]);
  }

  /// A game's row. Under a chapter a course's line is called by its own
  /// title — the header [ChapterGrouping.titleKey] names — rather than
  /// `Chapter – Line` as its player tags would read.
  GameSummary _summary(ChapterLine line, int index, ChapterGrouping grouping) {
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

  /// The filter applied: the list is another list.
  void _followTheFilter() {
    if (_filter.applied == _filterSeen) return;
    _filterSeen = _filter.applied;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
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

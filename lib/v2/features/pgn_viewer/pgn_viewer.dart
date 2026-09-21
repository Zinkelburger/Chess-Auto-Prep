import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../chess/pgn/chapter.dart';
import '../../chess/pgn/game_summary.dart';
import '../../storage/chapter_files.dart';
import '../../storage/pgn_file_picker.dart';
import '../../storage/recent_pgn_files.dart';
import '../../workspace/document_session.dart';

/// The PGN Viewer's own state: the files opened before, which file the
/// viewer has open now, and the search over its games.
///
/// The games themselves are not here. A viewed file is the document the
/// workspace has open, one game of it on the board, so the session holds
/// them and switching game is a command over it. This owner knows which
/// file is the viewer's and what to say about each game in the list.
final class PgnViewer extends ChangeNotifier {
  PgnViewer({
    required RecentFiles recent,
    required PgnFilePicker picker,
    required DocumentSession session,
    required String collections,
  }) : _recentFiles = recent,
       _picker = picker,
       _session = session,
       _collections = collections {
    _session.addListener(_followTheDocument);
  }

  /// How many files the list remembers, which is the old app's number.
  static const maxRecent = 10;

  final RecentFiles _recentFiles;
  final PgnFilePicker _picker;
  final DocumentSession _session;

  /// The `pgn_collections` folder, absolute: where the file dialog starts
  /// when nothing was opened before.
  final String _collections;

  List<String> _recent = const [];
  String? _recentProblem;
  ChapterRef? _file;
  Chapter? _rowsOf;
  List<GameSummary> _rows = const [];
  String _query = '';
  int _loads = 0;
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

  /// The games whose players, result or event match the search, paired
  /// with their place in the file, which is what opening one needs.
  List<(int, GameSummary)> get visible {
    final needle = _query.trim().toLowerCase();
    return [
      for (final (index, game) in games.indexed)
        if (needle.isEmpty || game.searchText.contains(needle)) (index, game),
    ];
  }

  String get query => _query;

  void search(String query) {
    if (query == _query) return;
    _query = query;
    notifyListeners();
  }

  /// Reads the recent list again. A load overtaken by a newer one discards
  /// its answer.
  Future<void> loadRecent() async {
    final ticket = ++_loads;
    final read = await _recentFiles.load();
    if (_disposed || ticket != _loads) return;
    switch (read) {
      case RecentFilesListed(:final paths):
        _recent = List.unmodifiable(paths);
        _recentProblem = null;
      case RecentFilesUnreadable():
        _recentProblem = 'The recent files could not be read.';
    }
    notifyListeners();
  }

  /// Asks the desktop for a file, starting beside the open one, else beside
  /// the last one, else in the collections folder. Null when the user
  /// closed the dialog without choosing.
  Future<String?> browse() {
    final near = file?.path ?? _recent.firstOrNull;
    return _picker.pickPgn(
      startIn: near == null ? _collections : p.dirname(near),
    );
  }

  /// [ref] is now the viewer's file: it goes to the top of the recent list,
  /// which is then kept. Called once the workspace has it open, so a file
  /// that could not be read is not remembered as one that was.
  Future<void> opened(ChapterRef ref) async {
    _file = ref;
    _query = '';
    _recent = List.unmodifiable(
      [ref.path, ..._recent.where((path) => path != ref.path)].take(maxRecent),
    );
    notifyListeners();
    final kept = await _recentFiles.save(_recent);
    if (_disposed) return;
    _recentProblem = kept ? null : 'The recent files list was not saved.';
    notifyListeners();
  }

  /// The viewer's file was closed, so the list of games goes with it.
  void closed() {
    _file = null;
    _query = '';
    notifyListeners();
  }

  void showGame(int index) => _session.showGame(index);

  void nextGame() {
    final at = current;
    if (at != null) showGame(at + 1);
  }

  void previousGame() {
    final at = current;
    if (at != null) showGame(at - 1);
  }

  /// The rows follow the document: a new chapter value means the games may
  /// have changed, so they are summarised again, once, for every reader.
  void _followTheDocument() {
    final chapter = _session.chapter;
    if (identical(chapter, _rowsOf)) return;
    _rowsOf = chapter;
    _rows = chapter == null
        ? const []
        : List.unmodifiable([
            for (final (index, line) in chapter.lines.indexed)
              summarizeGame(line, index: index),
          ]);
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _session.removeListener(_followTheDocument);
    super.dispose();
  }
}

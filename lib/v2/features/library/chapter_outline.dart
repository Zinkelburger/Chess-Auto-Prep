import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../chess/pgn/chapter.dart';
import '../../chess/pgn/game_text.dart';
import '../../chess/pgn/game_tree.dart';
import '../../chess/pgn/move_label.dart';
import '../../chess/pgn/tree_edit.dart';
import '../../storage/chapter_files.dart';
import '../../workspace/document_session.dart';
import 'library.dart';

/// One chapter of the open repertoire, as the outline lists it.
final class OutlineChapter {
  const OutlineChapter({required this.ref, required this.open, this.lines});

  final ChapterRef ref;

  /// This is the chapter on the board.
  final bool open;

  /// How many lines it holds, for the chapter on the board. Null for the
  /// others: their files are not read until they are opened, and a count is
  /// not worth reading a book-sized chapter for.
  final int? lines;

  String get name => ref.name;
}

/// One line of the open chapter: one game merged into its tree.
final class OutlineLine {
  const OutlineLine({
    required this.game,
    required this.name,
    required this.moves,
    required this.at,
    required this.text,
  });

  /// Where the line sits among the chapter's games, which is what an edit to
  /// it names.
  final int game;

  /// Its `[Event]` tag, or `Line 3` when it has nothing to be called.
  final String name;

  /// Its opening moves, for the row.
  final String moves;

  /// Its last move in the chapter's tree, which is where clicking it goes.
  final NodePath at;

  /// The line's name and all of its moves, lowercased: what the search
  /// matches, so a move deeper than the row shows is still findable.
  final String text;
}

/// The chapters of the repertoire the workspace has open, the lines of the
/// open chapter, and the search over both.
///
/// It owns the search — the words and the wait after them — and nothing
/// else: the chapters come from the [Library] and the lines from the
/// [DocumentSession], and both are read again whenever either of them says
/// something changed.
final class ChapterOutline extends ChangeNotifier {
  ChapterOutline({
    required Library library,
    required DocumentSession session,
    this.debounce = const Duration(milliseconds: 200),
  }) : _library = library,
       _session = session {
    _library.addListener(_reread);
    _session.addListener(_reread);
    _reread();
  }

  /// How many plies a line's row shows.
  static const shownPlies = 8;

  /// How long the list waits after a keystroke before it narrows. Long
  /// enough that typing a word does not rebuild the list once per letter,
  /// short enough to feel like it answered.
  final Duration debounce;

  final Library _library;
  final DocumentSession _session;

  String _typed = '';
  String _query = '';
  Timer? _waiting;
  Chapter? _chapter;
  List<OutlineLine> _lines = const [];
  bool _disposed = false;

  /// What the user has typed, which the field shows at once even though the
  /// list waits for [debounce].
  String get query => _typed;

  /// The repertoire the open chapter belongs to, or null when nothing is
  /// open or the library has not listed it.
  RepertoireFolder? get repertoire {
    final open = _session.source;
    if (open == null) return null;
    final folder = p.dirname(open.path);
    for (final listed in _library.repertoires) {
      if (listed.path == folder) return listed;
    }
    return null;
  }

  /// The chapters of that repertoire that match the search, in file order.
  List<OutlineChapter> get chapters {
    final open = _session.source;
    return [
      for (final ref in repertoire?.chapters ?? const <ChapterRef>[])
        if (_matches(ref.name.toLowerCase()) || _hasMatchingLine(ref))
          OutlineChapter(
            ref: ref,
            open: ref == open,
            lines: ref == open ? _session.chapter?.gameCount : null,
          ),
    ];
  }

  /// The lines of the open chapter that match the search, in file order.
  List<OutlineLine> get lines => [
    for (final line in _lines)
      if (_matches(line.text)) line,
  ];

  /// The line the cursor is inside, or null when it is on no line's moves —
  /// at the start, or on a move only another chapter's game plays.
  int? get currentLine {
    final chapter = _chapter;
    final cursor = _session.cursor;
    if (chapter == null || cursor.isRoot) return null;
    final sans = [for (final node in chapter.tree.lineTo(cursor)) node.san];
    for (final line in _lines) {
      final tree = chapter.treeInChapter(chapter.lines[line.game]);
      if (tree != null && pathOfSans(tree, sans) != null) return line.game;
    }
    return null;
  }

  /// Takes what the user typed and narrows the list once they stop.
  void search(String text) {
    if (text == _typed) return;
    _typed = text;
    _waiting?.cancel();
    _waiting = Timer(debounce, () => _narrow(text));
    notifyListeners();
  }

  void _narrow(String text) {
    if (_disposed || text == _query) return;
    _query = text;
    notifyListeners();
  }

  /// Reads the lines again when the chapter on the board is another value,
  /// and tells the panel either way: the cursor, the save state and the
  /// listing all show here.
  void _reread() {
    if (_disposed) return;
    final chapter = _session.chapter;
    if (!identical(chapter, _chapter)) {
      _chapter = chapter;
      _lines = chapter == null ? const [] : _linesOf(chapter);
    }
    notifyListeners();
  }

  bool _matches(String lowercased) =>
      _query.trim().isEmpty || lowercased.contains(_query.trim().toLowerCase());

  /// Whether a chapter the search did not match by name has a line that
  /// matches. Only the open chapter has lines to look at, so a search shows
  /// every other chapter by its name alone.
  bool _hasMatchingLine(ChapterRef ref) =>
      ref == _session.source && _lines.any((line) => _matches(line.text));

  @override
  void dispose() {
    _disposed = true;
    _waiting?.cancel();
    _library.removeListener(_reread);
    _session.removeListener(_reread);
    super.dispose();
  }
}

/// Every game of [chapter] that is merged into its tree, as a row.
///
/// A game that starts from another position, or that nothing could read, has
/// no place in the tree the board is showing, so the outline leaves it out
/// rather than offering a row that goes nowhere; the header counts it.
List<OutlineLine> _linesOf(Chapter chapter) {
  final rows = <OutlineLine>[];
  for (final (index, line) in chapter.lines.indexed) {
    final tree = chapter.treeInChapter(line);
    if (tree == null) continue;
    final sans = mainlineSans(tree);
    final name = tagValue(line.tags, 'Event')?.trim();
    rows.add(
      OutlineLine(
        game: index,
        name: name == null || name.isEmpty ? 'Line ${index + 1}' : name,
        moves: openingMoves(tree, plies: ChapterOutline.shownPlies),
        at: pathOfSans(chapter.tree, sans) ?? const NodePath.root(),
        text: '${name ?? ''} ${sans.join(' ')}'.toLowerCase(),
      ),
    );
  }
  return rows;
}

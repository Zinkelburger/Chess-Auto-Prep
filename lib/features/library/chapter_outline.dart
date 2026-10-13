import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../chess/pgn/chapter.dart';
import '../../chess/pgn/game_text.dart';
import '../../chess/pgn/game_tree.dart';
import '../../chess/pgn/move_label.dart';
import '../../chess/pgn/tree_edit.dart';
import '../../storage/chapter_files.dart';
import '../../ui/selection.dart';
import '../../workspace/document_session.dart';
import 'library.dart';

/// How many opening moves [sans] has in common with the line [above] it,
/// never all of them: a row with nothing in it would say even less than a
/// repeated one.
int _sharedWith(List<String> above, List<String> sans) {
  var shared = 0;
  while (shared < above.length &&
      shared < sans.length - 1 &&
      above[shared] == sans[shared]) {
    shared++;
  }
  return shared;
}

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
    this.positions = const {},
    this.shared = false,
  });

  /// Where the line sits among the chapter's games, which is what an edit to
  /// it names.
  final int game;

  /// Its `[Event]` tag, or `Line 3` when it has nothing to be called.
  final String name;

  /// Every line of the chapter carries this same name, which a generated
  /// chapter's lines do: they are all called after the chapter. A label that
  /// is the same on every row says nothing, so the row leaves it out and
  /// gives the space to the moves; renaming one still starts from it.
  final bool shared;

  /// Its opening moves, for the row.
  final String moves;

  /// Its last move in the chapter's tree, which is where clicking it goes.
  final NodePath at;

  /// The line's name and all of its moves, lowercased: what the search
  /// matches, so a move deeper than the row shows is still findable.
  final String text;

  /// Every position the line passes through, root included, as the four
  /// FEN fields: what the "At this position" filter matches, so a line that
  /// reaches the board's position by another move order is kept too.
  final Set<String> positions;
}

/// The chapters of the repertoire the workspace has open, the lines of the
/// open chapter, and the search over both.
///
/// It owns the search — the words and the wait after them — and nothing
/// else: the chapters come from the [Library] and the lines from the
/// [DocumentSession]. It tells the panel only when what it lists changed,
/// never for a cursor move or a save: whether a line is the one the cursor
/// is inside is [isCurrent], which the one row it concerns follows by itself.
final class ChapterOutline extends ChangeNotifier {
  ChapterOutline({
    required Library library,
    required DocumentSession session,
    Duration debounce = const Duration(milliseconds: 200),
  }) : _library = library,
       _session = session {
    _search = _Search(debounce, _narrowed);
    _library.addListener(_reread);
    _session.addListener(_reread);
    _session.cursorListenable.addListener(_followTheCursor);
    _currentRows.follow(_current);
    _reread();
  }

  /// How many plies a line's row shows.
  static const shownPlies = 8;

  final Library _library;
  final DocumentSession _session;

  late final _Search _search;
  Chapter? _chapter;
  ChapterRef? _source;
  List<RepertoireFolder>? _repertoires;
  List<OutlineLine> _lines = const [];
  NodePath _cursor = const NodePath.root();
  final _current = ValueNotifier<int?>(null);
  final _currentRows = Selection<int?>();
  bool _disposed = false;
  final _index = <ChapterRef, List<OutlineLine>>{};
  int _indexGeneration = 0;
  bool searching = false;
  String? searchProblem;

  /// Whether the open chapter's lines are narrowed to those passing
  /// through the position on the board.
  bool get atPosition => _atPosition;
  bool _atPosition = false;

  /// The board's position the filter last narrowed to.
  String? _filteredAt;

  /// Turns the "At this position" filter on or off.
  void showAtPosition(bool on) {
    if (on == _atPosition) return;
    _atPosition = on;
    _filteredAt = on ? _session.fen.position : null;
    notifyListeners();
  }

  List<OutlineLine> matchesIn(ChapterRef ref) => ref == _session.source
      ? lines
      : [
          for (final line in _index[ref] ?? const <OutlineLine>[])
            if (_matches(line.text)) line,
        ];

  Future<void> _indexChapters() async {
    final generation = ++_indexGeneration;
    searchProblem = null;
    if (_search.typed.trim().isEmpty) {
      searching = false;
      return;
    }
    searching = true;
    notifyListeners();
    for (final ref in repertoire?.chapters ?? const <ChapterRef>[]) {
      if (_index.containsKey(ref) || ref == _session.source) continue;
      try {
        final chapter = await _library.chapterForSearch(ref);
        if (_disposed || generation != _indexGeneration) return;
        if (chapter == null) {
          searchProblem = 'Some chapters could not be searched.';
          continue;
        }
        _index[ref] = _linesOf(chapter);
      } on Object {
        if (_disposed || generation != _indexGeneration) return;
        searchProblem = 'Some chapters could not be searched.';
      }
    }
    if (_disposed || generation != _indexGeneration) return;
    searching = false;
    notifyListeners();
  }

  /// What the user has typed, which the field shows at once even though the
  /// list waits a moment before it narrows.
  String get query => _search.typed;

  /// The repertoire the open chapter belongs to, or null when nothing is
  /// open or the library has not listed it.
  RepertoireFolder? get repertoire {
    final open = _session.source;
    if (open == null) return null;
    for (final listed in _library.repertoires) {
      if (listed.chapters.any((chapter) => chapter.path == open.path)) {
        return listed;
      }
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

  /// The lines of the open chapter that match the search, in file order,
  /// and, while [atPosition] is on, pass through the board's position.
  List<OutlineLine> get lines {
    final at = _atPosition ? _session.fen.position : null;
    return [
      for (final line in _lines)
        if (_matches(line.text) && (at == null || line.positions.contains(at)))
          line,
    ];
  }

  /// Whether the line at [game] is the one the cursor is inside, notifying
  /// only when that changes: what one row listens to, so the cursor going
  /// from one line to another redraws two rows rather than every row on
  /// screen. No line is, at the start or on a move only another chapter's
  /// game plays.
  ///
  /// Which line that is gets worked out once for each place the cursor goes,
  /// not once for each row that asks: finding it walks every line's moves,
  /// and a book of a thousand lines would then cost a thousand walks per
  /// row. A step forward usually costs one: see [_followTheCursor].
  ValueListenable<bool> isCurrent(int game) => _currentRows.of(game);

  /// What the line at [game] is called now, whatever the search is showing,
  /// or null when the chapter has no such line any more.
  String? nameOf(int game) {
    for (final line in _lines) {
      if (line.game == game) return line.name;
    }
    return null;
  }

  /// Takes what the user typed and narrows the list once they stop.
  void search(String text) {
    if (_search.type(text)) notifyListeners();
  }

  void _narrowed() {
    if (!_disposed) {
      notifyListeners();
      unawaited(_indexChapters());
    }
  }

  /// Reads the lines again when the chapter on the board is another value,
  /// and tells the panel when anything it lists changed: another chapter,
  /// file or listing. An edit that refused, a flip or a busy library change
  /// nothing here, so they rebuild nothing.
  void _reread() {
    if (_disposed) return;
    final chapter = _session.chapter;
    final source = _session.source;
    final repertoires = _library.repertoires;
    if (identical(chapter, _chapter) &&
        source == _source &&
        identical(repertoires, _repertoires)) {
      return;
    }
    if (!identical(chapter, _chapter)) {
      _chapter = chapter;
      _lines = chapter == null ? const [] : _linesOf(chapter);
      _cursor = _session.cursor;
      _current.value = _lineHolding(_cursor);
    }
    if (!identical(repertoires, _repertoires)) _index.clear();
    if (source != null) _index.remove(source);
    _source = source;
    _repertoires = repertoires;
    unawaited(_indexChapters());
    notifyListeners();
  }

  /// Keeps the current line ([isCurrent]) the one the cursor is inside.
  ///
  /// Going deeper can only narrow which lines play the moves to the cursor,
  /// so a step forward keeps the line it was in whenever that line still
  /// plays it: the first of a smaller set that still holds it is still the
  /// first. Likewise no line holding the move before means none holds the
  /// move after. Only a step back or aside walks every line again.
  void _followTheCursor() {
    // A move that was just written moves the cursor before the session says
    // the chapter changed; the lines are read again when it does.
    if (_disposed || !identical(_session.chapter, _chapter)) return;
    _refilter();
    final from = _cursor;
    final to = _session.cursor;
    _cursor = to;
    final current = _current.value;
    final deeper = _extends(to, from) && !from.isRoot;
    if (deeper && (current == null || _holds(current, to))) return;
    _current.value = _lineHolding(to);
  }

  /// While the position filter is on, a cursor move to another position
  /// changes which lines are listed; one that stays on it changes nothing.
  void _refilter() {
    if (!_atPosition) return;
    final at = _session.fen.position;
    if (at == _filteredAt) return;
    _filteredAt = at;
    notifyListeners();
  }

  /// Which line plays the moves down to [cursor]; the first of them when
  /// several do, as the tree shows them once.
  int? _lineHolding(NodePath cursor) {
    if (_chapter == null || cursor.isRoot) return null;
    for (final line in _lines) {
      if (_holds(line.game, cursor)) return line.game;
    }
    return null;
  }

  /// Whether the line at [game] plays the moves down to [cursor].
  bool _holds(int game, NodePath cursor) {
    final chapter = _chapter;
    if (chapter == null || game >= chapter.lines.length) return false;
    final tree = chapter.treeInChapter(chapter.lines[game]);
    if (tree == null) return false;
    final sans = [for (final node in chapter.tree.lineTo(cursor)) node.san];
    return pathOfSans(tree, sans) != null;
  }

  bool _matches(String lowercased) => _search.matches(lowercased);

  /// Whether a chapter the search did not match by name has a line that
  /// matches. Closed chapters are indexed on demand after the debounce.
  bool _hasMatchingLine(ChapterRef ref) => matchesIn(ref).isNotEmpty;

  @override
  void dispose() {
    _disposed = true;
    _search.cancel();
    _library.removeListener(_reread);
    _session.removeListener(_reread);
    _session.cursorListenable.removeListener(_followTheCursor);
    _currentRows.dispose();
    _current.dispose();
    super.dispose();
  }
}

/// The words in the search field and the wait after them: the field shows
/// what was typed at once, the list narrows to it once typing stops.
final class _Search {
  _Search(this._debounce, this._narrowed);

  /// How long the list waits after a keystroke before it narrows. Long
  /// enough that typing a word does not rebuild the list once per letter,
  /// short enough to feel like it answered.
  final Duration _debounce;

  /// Told when the list narrows to what was typed.
  final void Function() _narrowed;

  String _typed = '';
  String _query = '';
  Timer? _waiting;

  String get typed => _typed;

  /// Takes [text] and starts the wait; false when nothing changed.
  bool type(String text) {
    if (text == _typed) return false;
    _typed = text;
    _waiting?.cancel();
    _waiting = Timer(_debounce, () => _narrow(text));
    return true;
  }

  void _narrow(String text) {
    if (text == _query) return;
    _query = text;
    _narrowed();
  }

  bool matches(String lowercased) =>
      _query.trim().isEmpty || lowercased.contains(_query.trim().toLowerCase());

  void cancel() => _waiting?.cancel();
}

/// Whether [path] goes through [from]: the same moves, then more.
bool _extends(NodePath path, NodePath from) {
  if (path.indexes.length <= from.indexes.length) return false;
  for (final (i, index) in from.indexes.indexed) {
    if (path.indexes[i] != index) return false;
  }
  return true;
}

/// Every game of [chapter] that is merged into its tree, as a row.
///
/// A game that starts from another position, or that nothing could read, has
/// no place in the tree the board is showing, so the outline leaves it out
/// rather than offering a row that goes nowhere; the header counts it.
///
/// A row shows its line from the move where it leaves every line above it.
/// A generated chapter's lines share their whole opening — often every move
/// a row has room for — so rows that all began at the first move would read
/// the same and tell the user nothing about which line is which; and lines
/// of one branch need not sit together, so leaving only the line just above
/// would still start two rows at the same move.
List<OutlineLine> _linesOf(Chapter chapter) {
  final rows = <OutlineLine>[];
  final names = <String>{};
  final above = <List<String>>[];
  for (final (index, line) in chapter.lines.indexed) {
    final tree = chapter.treeInChapter(line);
    if (tree == null) continue;
    final sans = mainlineSans(tree);
    final shared = above.fold(
      0,
      (most, other) => math.max(most, _sharedWith(other, sans)),
    );
    above.add(sans);
    final name = tagValue(line.tags, 'Event')?.trim();
    if (name != null) names.add(name);
    rows.add(
      OutlineLine(
        game: index,
        name: line.nameAt(index),
        moves: movesFrom(tree, plies: ChapterOutline.shownPlies, skip: shared),
        at: pathOfSans(chapter.tree, sans) ?? const NodePath.root(),
        text: '${name ?? ''} ${sans.join(' ')}'.toLowerCase(),
        positions: _positionsOf(tree),
      ),
    );
  }
  if (names.length != 1 || rows.length < 2) return rows;
  return [
    for (final row in rows)
      OutlineLine(
        game: row.game,
        name: row.name,
        moves: row.moves,
        at: row.at,
        text: row.text,
        positions: row.positions,
        shared: true,
      ),
  ];
}

/// The positions [tree]'s main line passes through, its root included.
Set<String> _positionsOf(GameTree tree) {
  final positions = {tree.rootFen.position};
  var children = tree.children;
  while (children.isNotEmpty) {
    positions.add(children.first.fen.position);
    children = children.first.children;
  }
  return positions;
}

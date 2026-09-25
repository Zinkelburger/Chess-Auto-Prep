import 'dart:async';

import 'package:dartchess/dartchess.dart' show Move, Side;
import 'package:flutter/foundation.dart';

import '../chess/fen.dart';
import '../chess/pgn/game_tree.dart';
import '../chess/pgn/move_label.dart' show continuation;
import '../chess/repertoire_index.dart';
import '../chess/pgn/tree_edit.dart' show moveNode;
import '../storage/chapter_files.dart';
import '../diagnostics/log.dart';
import 'board_claim.dart';
import 'books.dart';
import 'document_session.dart';
import 'gap_walk.dart' show indexOfReply;
import 'repertoire_shelf.dart';

/// Where one move of the repertoires can be read: the file, and the moves from
/// that file's start to the position after it.
final class TreePlace {
  const TreePlace(this.ref, this.sans);

  final ChapterRef ref;
  final List<String> sans;
}

/// One move the repertoires play from the position on the board.
final class TreeRow {
  const TreeRow({
    required this.uci,
    required this.san,
    required this.after,
    required this.lines,
    required this.places,
    required this.goesOn,
    required this.here,
  });

  final String uci;
  final String san;

  /// The position it leaves behind, for the small board under the pointer.
  final Fen after;

  /// How many lines of the repertoires go through it, every file counted.
  final int lines;

  /// Every file that plays it, most lines first.
  final List<TreePlace> places;

  /// How the file with the most lines goes on after it: `4.Ba4 Nf6 5.O-O …`.
  final String goesOn;

  /// Whether the document on the board plays it here, so a click only
  /// steps into it.
  final bool here;

  /// The files' names, most lines first, each once.
  List<String> get names =>
      {for (final place in places) place.ref.name}.toList();
}

sealed class TreeState {
  const TreeState();
}

/// The repertoires are being read; nothing to show yet.
final class TreeReading extends TreeState {
  const TreeReading();
}

final class TreeShown extends TreeState {
  const TreeShown(this.rows);

  /// Most lines first.
  final List<TreeRow> rows;
}

/// The repertoires say nothing here, and [sentence] says so.
final class TreeNothing extends TreeState {
  const TreeNothing(this.sentence);

  final String sentence;
}

/// A required input could not be read or has not finished saving.
final class TreeUnavailable extends TreeState {
  const TreeUnavailable(this.detail);
  final String detail;
}

/// Every line of the user's repertoires, looked up by position: what they play
/// from the position on the board, in whichever file, however the board
/// got there.
///
/// The repertoires are the chapters of the active book ([Books]) for the
/// side the board is shown from; with no book set there is nothing to show.
/// Draft chapters are left out, since a proposal is not a line the user
/// plays. Positions are matched without the move counters, so a
/// transposition finds the lines the other move order wrote.
///
/// Each file is read and indexed once and kept until its bytes change:
/// [forget] marks them to be read again, and only a file whose bytes are
/// not what was indexed is parsed again. The file on the board is taken
/// from the session instead, as it stands, so a move just added shows at
/// once.
///
/// While the explorer's Book is up the board is a free board: a move the file on
/// it does not play is not written into it but played on [board], past the
/// file's position, and the tree follows it there. Taking those moves back,
/// moving in the file or leaving the tab gives the board back to the file.
final class RepertoireTree extends ChangeNotifier {
  RepertoireTree({
    required DocumentSession session,
    required RepertoireShelf shelf,
    required Books books,
  }) : _session = session,
       _shelf = shelf,
       _books = books {
    _session.anyChange.addListener(_followTheBoard);
    _bookRevision = _books.revision;
    _books.addListener(_bookChanged);
    _shelf.addListener(_shelfChanged);
  }

  /// Plies of a line's continuation a row shows.
  static const goesOnPlies = 8;

  final DocumentSession _session;

  /// The files on disk, indexed; shared with the book check.
  final RepertoireShelf _shelf;

  /// Which of the files count: the active book's.
  final Books _books;

  /// The file on the board, indexed from the session's own tree.
  ({GameTree tree, RepertoireIndex index})? _live;

  int _watching = 0;
  TreeState _state = const TreeReading();
  ({GameTree? tree, NodePath at, Side side})? _board;
  bool _disposed = false;

  /// The position past the file's while moves off the file are on the
  /// board; null while the board shows the file.
  final board = ValueNotifier<BoardClaim?>(null);

  /// The moves played on the board past the file's position.
  final _off = <MoveNode>[];

  TreeState get state => _state;

  int? _shownShelf;
  int? _shownBook;
  ({int book, int? shelf})? _validated;
  Future<void>? _reading;
  int _generation = 0;

  /// Cursor projections reuse one validated immutable shelf/selection pair.
  bool get _bundleCurrent =>
      _validated ==
      (
        book: _books.revision,
        shelf: _books.active == null ? null : _shelf.version,
      );
  bool get current =>
      _inputsCurrent &&
      _bundleCurrent &&
      _shownShelf == _shelf.version &&
      _shownBook == _books.revision;
  bool get _inputsCurrent =>
      _books.current && (_books.active == null || !_shelf.stale);

  /// Whether a pane showing the tree is up, and the board is its.
  bool get watching => _watching > 0;

  /// The moves played past the file's position, in order.
  List<MoveNode> get offFile => List.unmodifiable(_off);

  /// The position the tree is about: the file's, or past it.
  Fen get fen => _off.isEmpty ? _session.fen : _off.last.fen;

  /// A move made on the board or clicked in the tree: a step in the file
  /// when the file plays it here, else a move on the free board. The
  /// analysis board takes every move itself, so it needs no free board.
  void play(String uci) {
    if (_session.isScratch) return _session.playMove(uci);
    if (_off.isEmpty) {
      final tree = _session.tree;
      if (tree == null) return;
      final at = _session.cursor;
      final siblings = tree.nodeAt(at)?.children ?? tree.children;
      final index = indexOfReply(_session.fen, siblings, uci);
      if (index >= 0) return _session.goTo(at.child(index));
    }
    final move = Move.parse(uci);
    final node = move == null ? null : moveNode(fen, move);
    if (node == null) return;
    _off.add(node);
    _offChanged();
  }

  /// Takes back the last move off the file, or steps back in the file when
  /// there is none: what ← does.
  void back() {
    if (_off.isEmpty) return _session.back();
    _off.removeLast();
    _offChanged();
  }

  /// Takes back every move off the file.
  void backToFile() {
    if (_off.isEmpty) return;
    _off.clear();
    _offChanged();
  }

  void _offChanged() {
    board.value = _off.isEmpty
        ? null
        : BoardClaim(
            fen: _off.last.fen,
            orientation: _session.orientation,
            onMove: play,
            lastMove: _off.last.uci,
          );
    _refresh();
  }

  /// The side whose repertoires are shown: the one the board is seen from.
  Side get side => _session.orientation;

  /// How many files the repertoires of [side] are, once read.
  int get fileCount => _inBook
      .where((ref) => (_liveFor(ref) ?? _shelf.indexOf(ref))?.side == side)
      .length;

  /// The name of the book the tree is of, or null while none is set.
  String? get bookName => _books.active?.name;

  /// The chapters on the shelf that are in the active book.
  Iterable<ChapterRef> get _inBook => _shelf.refs.where(_books.includes);

  /// The files changed on disk: they are read again now if a pane is up,
  /// else when one comes up, and only the ones whose bytes changed are
  /// parsed again. The board stays where it is, free board and all.
  void forget() {
    _validated = null;
    _shelf.forget();
    _refresh();
  }

  /// Retry the complete inputs, including a retained failed selection save.
  Future<void> retry() async {
    if (_disposed) return;
    _validated = null;
    if (_books.canRetry) {
      await _books.retry();
    } else {
      await _books.load();
    }
    if (_disposed) return;
    forget();
    while (_reading != null) {
      await _reading;
    }
  }

  /// A pane showing the tree says so while it is up: the files are read
  /// and the board followed only while someone is looking.
  void watch() {
    if (_watching++ == 0) {
      _generation++;
      _validated = null;
      _board = null;
      _followTheBoard();
    }
  }

  /// The pane went: the board is the file's again.
  void unwatch() {
    if (_disposed) return;
    if (_watching > 0) _watching--;
    if (_watching == 0) {
      _generation++;
      backToFile();
    }
  }

  void _followTheBoard() {
    if (_disposed || _watching == 0) return;
    final board = (tree: _session.tree, at: _session.cursor, side: side);
    final seen = _board;
    if (seen != null &&
        identical(seen.tree, board.tree) &&
        seen.at == board.at &&
        seen.side == board.side) {
      return;
    }
    _board = board;
    // Moving in the file leaves the free board; a flip only turns it.
    if (_off.isNotEmpty) {
      final moved =
          seen == null ||
          !identical(seen.tree, board.tree) ||
          seen.at != board.at;
      if (moved) _off.clear();
      return _offChanged();
    }
    _refresh();
  }

  /// The rows for the position now, once the files are read: a reader that
  /// gave up, or another that told the shelf the files changed, leaves it
  /// stale, and then it is read again first.
  int _bookRevision = 0;
  void _bookChanged() {
    if (_bookRevision != _books.revision) {
      _bookRevision = _books.revision;
      // Files outside the previous selection may have changed without
      // invalidating its displayed bundle. Observe the new selection afresh.
      _shelf.forget();
    }
    _refresh();
  }

  void _refresh() {
    if (_disposed || _watching == 0) return;
    if (!_books.current) {
      _validated = null;
      _show(
        TreeUnavailable(
          _books.problem ?? 'The book selection is being saved or read.',
        ),
      );
    } else if (!_inputsCurrent || !_bundleCurrent) {
      _show(const TreeReading());
      unawaited(_readThenShow());
    } else {
      _showHere();
    }
  }

  void _shelfChanged() {
    if (_disposed || _watching == 0) return;
    if (_shelf.problem != null) {
      _showHere();
    } else {
      _refresh();
    }
  }

  Future<void> _readThenShow() => _reading ??= _readInputs().whenComplete(() {
    _reading = null;
    // An owner change during the fence leaves Reading for the replacement;
    // an actual failed read stays unavailable until an explicit retry.
    if (!_disposed && _watching > 0 && _state is TreeReading) _refresh();
  });

  Future<void> _readInputs() async {
    final generation = _generation;
    final bookRevision = _books.revision;
    final source = _books.source;
    final hasBook = _books.active != null;
    bool gone() =>
        _disposed ||
        _watching == 0 ||
        generation != _generation ||
        bookRevision != _books.revision ||
        !_books.current;
    try {
      if (hasBook) {
        await _shelf.read(gone: gone);
        if (gone()) return;
        if (_shelf.stale) {
          // A fresh invalidation can land between read completion and this
          // continuation. Let the queued replacement read run; only a failed
          // shelf read is an unavailable input.
          if (_shelf.problem case final detail?) _unavailable(detail);
          return;
        }
      }
      final version = hasBook ? _shelf.version : null;
      final checked = hasBook
          ? await _shelf.validate(
              version: version!,
              book: source,
              boundaries: _books.inputs(_books.active),
            )
          : await _shelf.validateBook(source);
      if (gone()) return;
      if (hasBook && (_shelf.stale || version != _shelf.version)) return;
      switch (checked) {
        case RepertoireCurrent():
          _validated = (book: bookRevision, shelf: version);
          // The cursor is intentionally read now, synchronously: it is a
          // projection of the validated bundle, not another native input.
          _showHere();
        case RepertoireChanged():
          _unavailable('The book inputs changed. Retry.');
        case RepertoireValidationFailed(:final detail):
          _unavailable(detail);
      }
    } on Object catch (error) {
      if (!gone()) _unavailable('The book could not be read: $error');
    }
  }

  void _unavailable(String detail) {
    log.w('read the repertoire tree inputs', detail);
    _show(TreeUnavailable(detail));
  }

  /// The file on the board when it is one of the repertoires, indexed from the
  /// session's tree as it stands now.
  RepertoireIndex? _liveFor(ChapterRef ref) {
    final chapter = _session.chapter;
    final tree = _session.tree;
    if (_session.source != ref || chapter == null || tree == null) return null;
    if (chapter.game != null) return null;
    final live = _live;
    // Playing the chapter from the other side keeps its tree.
    if (live != null &&
        identical(live.tree, tree) &&
        live.index.side == chapter.side) {
      return live.index;
    }
    final index = RepertoireIndex.of(tree, chapter.side);
    _live = (tree: tree, index: index);
    return index;
  }

  void _showHere() {
    if (!_inputsCurrent || !_bundleCurrent) {
      _show(
        TreeUnavailable(
          _books.problem ?? _shelf.problem ?? 'The book inputs changed. Retry.',
        ),
      );
      return;
    }
    final fen = this.fen;
    final key = fen.position;
    final side = this.side;
    final merged = <String, List<(IndexedMove, ChapterRef)>>{};
    var files = 0;
    if (_books.active == null) {
      _show(const TreeNothing('No book set.'));
      return;
    }
    for (final ref in _inBook) {
      final index = _liveFor(ref) ?? _shelf.indexOf(ref);
      if (index == null || index.side != side) continue;
      files++;
      final moves = index.movesAt(key);
      if (moves == null) continue;
      for (final seen in moves.values) {
        (merged[seen.node.uci] ??= []).add((seen, ref));
      }
    }
    final name = side == Side.white ? 'White' : 'Black';
    if (files == 0) {
      _show(TreeNothing('Your book has no $name chapters.'));
      return;
    }
    if (merged.isEmpty) {
      _show(TreeNothing('Your book has no $name move here.'));
      return;
    }
    final tree = _session.tree;
    final siblings = tree?.nodeAt(_session.cursor)?.children ?? tree?.children;
    final rows = [
      for (final seen in merged.values)
        _row(
          seen,
          here: (uci) =>
              _off.isEmpty &&
              siblings != null &&
              indexOfReply(fen, siblings, uci) >= 0,
        ),
    ];
    rows.sort((a, b) => b.lines.compareTo(a.lines));
    _show(TreeShown(List.unmodifiable(rows)));
  }

  /// One move as every file that plays it here has it, the file with the
  /// most lines first.
  static TreeRow _row(
    List<(IndexedMove, ChapterRef)> seen, {
    required bool Function(String uci) here,
  }) {
    seen.sort((a, b) => b.$1.lines.compareTo(a.$1.lines));
    final first = seen.first.$1.node;
    return TreeRow(
      uci: first.uci,
      san: first.san,
      after: first.fen,
      lines: seen.fold(0, (sum, s) => sum + s.$1.lines),
      places: [for (final (s, ref) in seen) TreePlace(ref, s.sans)],
      goesOn: continuation(first, plies: goesOnPlies),
      here: here(first.uci),
    );
  }

  void _show(TreeState state) {
    if (_disposed) return;
    _state = state;
    if (state is TreeShown || state is TreeNothing) {
      _shownShelf = _shelf.version;
      _shownBook = _books.revision;
    } else {
      _shownShelf = null;
      _shownBook = null;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _session.anyChange.removeListener(_followTheBoard);
    _books.removeListener(_bookChanged);
    _shelf.removeListener(_shelfChanged);
    board.dispose();
    super.dispose();
  }
}

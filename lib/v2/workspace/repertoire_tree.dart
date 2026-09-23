import 'dart:async';

import 'package:dartchess/dartchess.dart' show Move, Side;
import 'package:flutter/foundation.dart';

import '../chess/fen.dart';
import '../chess/pgn/game_tree.dart';
import '../chess/pgn/move_label.dart' show continuation;
import '../chess/repertoire_index.dart';
import '../chess/pgn/tree_edit.dart' show moveNode;
import '../storage/chapter_files.dart';
import 'board_claim.dart';
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

/// Every line of the user's repertoires, looked up by position: what they play
/// from the position on the board, in whichever file, however the board
/// got there.
///
/// The repertoires are every repertoire of the side the board is shown from; a
/// repertoire of one file with no chapters is one like any other.
/// Draft chapters are left out, since a proposal is not a line the user
/// plays. Positions are matched without the move counters, so a
/// transposition finds the lines the other move order wrote.
///
/// Each file is read and indexed once and kept until its text changes:
/// [forget] marks them to be read again, and only a file whose text is not
/// what was indexed is parsed again. The file on the board is taken from
/// the session instead, as it stands, so a move just added shows at once.
///
/// While the Tree tab is up the board is a free board: a move the file on
/// it does not play is not written into it but played on [board], past the
/// file's position, and the tree follows it there. Taking those moves back,
/// moving in the file or leaving the tab gives the board back to the file.
final class RepertoireTree extends ChangeNotifier {
  RepertoireTree({
    required DocumentSession session,
    required RepertoireShelf shelf,
  }) : _session = session,
       _shelf = shelf {
    _session.anyChange.addListener(_followTheBoard);
  }

  /// Plies of a line's continuation a row shows.
  static const goesOnPlies = 8;

  final DocumentSession _session;

  /// The files on disk, indexed; shared with the book check.
  final RepertoireShelf _shelf;

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

  /// Whether a pane showing the tree is up, and the board is its.
  bool get watching => _watching > 0;

  /// The moves played past the file's position, in order.
  List<MoveNode> get offFile => List.unmodifiable(_off);

  /// The position the tree is about: the file's, or past it.
  Fen get fen => _off.isEmpty ? _session.fen : _off.last.fen;

  /// A move made on the board or clicked in the tree: a step in the file
  /// when the file plays it here, else a move on the free board.
  void play(String uci) {
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
    if (_watching > 0 && !_shelf.stale) _showHere();
  }

  /// The side whose repertoires are shown: the one the board is seen from.
  Side get side => _session.orientation;

  /// How many files the repertoires of [side] are, once read.
  int get fileCount => _shelf.refs
      .where((ref) => (_liveFor(ref) ?? _shelf.indexOf(ref))?.side == side)
      .length;

  /// The files changed on disk: they are read again the next time the
  /// board moves, and only the ones whose text changed are parsed again.
  void forget() {
    _shelf.forget();
    _board = null;
    _followTheBoard();
  }

  /// A pane showing the tree says so while it is up: the files are read
  /// and the board followed only while someone is looking.
  void watch() {
    if (_watching++ == 0) {
      _board = null;
      _followTheBoard();
    }
  }

  /// The pane went: the board is the file's again.
  void unwatch() {
    if (_disposed) return;
    if (_watching > 0) _watching--;
    if (_watching == 0) backToFile();
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
      _offChanged();
      if (!_shelf.stale) return;
    }
    if (_shelf.stale) {
      unawaited(_readThenShow());
    } else {
      _showHere();
    }
  }

  Future<void> _readThenShow() async {
    await _shelf.read(gone: () => _disposed);
    if (_disposed || _watching == 0) return;
    _showHere();
  }

  /// The file on the board when it is one of the repertoires, indexed from the
  /// session's tree as it stands now.
  RepertoireIndex? _liveFor(ChapterRef ref) {
    final chapter = _session.chapter;
    final tree = _session.tree;
    if (_session.source != ref || chapter == null || tree == null) return null;
    if (chapter.game != null) return null;
    final live = _live;
    if (live != null && identical(live.tree, tree)) return live.index;
    final index = RepertoireIndex.of(tree, chapter.side);
    _live = (tree: tree, index: index);
    return index;
  }

  void _showHere() {
    final fen = this.fen;
    final key = fen.position;
    final side = this.side;
    final merged = <String, List<(IndexedMove, ChapterRef)>>{};
    var files = 0;
    for (final ref in _shelf.refs) {
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
      _show(TreeNothing('No $name repertoires yet.'));
      return;
    }
    if (merged.isEmpty) {
      _show(TreeNothing('Your $name repertoires have no move here.'));
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
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _session.anyChange.removeListener(_followTheBoard);
    board.dispose();
    super.dispose();
  }
}

import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../chess/fen.dart';
import '../chess/pgn/analysis_board.dart';
import '../chess/pgn/chapter.dart';
import '../chess/pgn/chapter_edit.dart' as edits;
import '../chess/pgn/chapter_edits.dart' as edits;
import '../chess/pgn/chapter_sections.dart';
import '../chess/pgn/comment_edits.dart' as edits;
import '../chess/pgn/game_tree.dart';
import '../chess/pgn/games_written.dart';
import '../chess/pgn/line_id_pins.dart';
import '../chess/pgn/tree_edit.dart';
import '../diagnostics/log.dart';
import '../storage/chapter_files.dart';
import '../storage/document_ref.dart';
import '../storage/edit_scope.dart';
import '../storage/pgn_document_store.dart' as store;
import 'document_saver.dart';
import 'session_results.dart';

/// The document open in the workspace, where the user is in it, and the
/// edits they make to it.
///
/// Holds the chapter (an immutable value), the file it came from and the
/// cursor. The board, the move list and every panel derive what they show
/// from these; nothing else in the workspace keeps a copy of the tree, the
/// position or which file is open. Writing belongs to the [DocumentSaver]
/// this session was given: an edit replaces the chapter and hands the saver
/// the new file text.
///
/// It notifies in two parts, so a listener hears only what it shows. The
/// session itself notifies when the document changes — another chapter or
/// game, an edit, a refusal, a flip — and [cursorListenable] when the cursor
/// moves, which is every arrow key: the library, the outline and the game
/// list never need to hear that. What follows the position, the board and
/// the engine, listens to [anyChange]. The chapter is always replaced before
/// the cursor moves into it, so a cursor listener never reads a path the
/// tree does not have yet.
final class DocumentSession extends ChangeNotifier {
  DocumentSession(this._store, this._saver) {
    _shown = (chapter: _board.chapter, view: null);
  }

  final store.PgnDocumentStore _store;
  final DocumentSaver _saver;

  /// The chapter on the board, and — when it is one of several a file holds
  /// by tag — the file and where its games sit in it; the view is null when
  /// the chapter is the whole file. Edits are made to the chapter and, with
  /// a view, put back into the file. One field, so the two cannot disagree.
  ({Chapter chapter, SectionView? view})? _shown;

  Chapter? get _chapter => _shown?.chapter;
  SectionView? get _view => _shown?.view;

  /// The file the chapter came from and why it may not be written; null
  /// while the analysis board is up.
  ({ChapterRef ref, String? readOnly})? _file;

  ChapterRef? get _source => _file?.ref;
  String? get _readOnly => _file?.readOnly;

  /// The analysis board, up whenever no file is; the window starts on it.
  final _board = KeptBoard(analysisBoard(side: Side.white));
  final _cursor = ValueNotifier<NodePath>(const NodePath.root());
  EditRefused? _refused;
  NodePath? _shownTo;
  bool _flipped = false;
  int _opens = 0;
  bool _disposed = false;

  Chapter? get chapter => _chapter;

  /// Why the last edit did not happen, or null when it did. A game reading
  /// could not finish keeps its own bytes, so an edit that would write it is
  /// refused, and so are words a PGN file cannot hold and every edit to a
  /// file this app may not write. The next edit clears this, as does opening
  /// another document.
  EditRefused? get refusedEdit => _refused;

  /// Why this document cannot be written, or null when it can.
  String? get readOnly => _readOnly;

  /// Whether the analysis board is up: a chapter no file holds, whose edits
  /// stay in memory and are lost with the window.
  bool get isScratch => _chapter != null && _source == null;

  /// Whether an edit can be taken back now: from the saver's receipts for a
  /// file, from memory on the analysis board.
  bool get canUndo => isScratch ? _board.canUndo : _saver.canUndo;

  /// The file the chapter was read from, and which game of it is on the
  /// board — null when its games are merged. A repertoire chapter is the
  /// file; a study chapter is one game.
  ChapterRef? get source => _source;

  int? get game => _chapter?.game;
  GameTree? get tree => _chapter?.tree;

  NodePath get cursor => _cursor.value;

  /// Notifies when the cursor moves, and only then.
  ValueListenable<NodePath> get cursorListenable => _cursor;

  /// Notifies for a cursor move and for everything the session notifies
  /// for: what a view of the position, rather than of the document, needs.
  /// One object for the session's life, so a widget rebuilt with it keeps
  /// its subscription.
  late final Listenable anyChange = Listenable.merge([this, _cursor]);

  Fen get fen => tree?.fenAt(cursor) ?? Fen.initial;

  /// The side at the bottom of the board: the repertoire's side, or a study
  /// chapter's own orientation tag, turned over while the user has flipped
  /// the board. Opening another document turns it back.
  Side get orientation {
    final side = _chapter?.side ?? Side.white;
    return _flipped ? side.opposite : side;
  }

  bool get flipped => _flipped;

  /// While set, the game is shown only as far as this move: the moves after
  /// it and every note are hidden, the cursor cannot pass it, and the board
  /// plays nothing into the document. A puzzle asks the user to find what
  /// comes next, so the answer must not be one arrow key or one glance at
  /// the move list away. Null shows everything.
  ///
  /// Another document or another game of this one shows everything again;
  /// whoever hid the rest hides it again for the game they put up.
  NodePath? get shownTo => _shownTo;

  /// Shows the game only as far as [path], or all of it when null. A cursor
  /// past [path] is brought back to it.
  void showOnlyTo(NodePath? path) {
    if (path == _shownTo) return;
    _shownTo = path;
    notifyListeners();
    if (path != null && !path.startsWith(cursor)) _cursor.value = path;
  }

  /// Turns the board over. On the analysis board, which no file says the
  /// side of, that changes sides: a search from it plays for the bottom.
  void flip() {
    final chapter = _chapter;
    if (isScratch && chapter != null) {
      _shown = (chapter: withSide(chapter, chapter.side.opposite), view: null);
    } else {
      _flipped = !_flipped;
    }
    notifyListeners();
  }

  /// How many games the open file has when one of them is on the board;
  /// null for a merged chapter, which shows no one game.
  int? get gameCount => game == null ? null : _chapter?.lines.length;

  void nextGame() {
    if (game case final at?) showGame(at + 1);
  }

  void previousGame() {
    if (game case final at?) showGame(at - 1);
  }

  /// The move the cursor is on; null at the root.
  MoveNode? get currentMove => tree?.nodeAt(cursor);

  /// The comment on the move at [at], or the chapter's introduction at the
  /// root; machine tokens included.
  String? commentAt(NodePath at) =>
      at.isRoot ? tree?.rootComment : tree?.nodeAt(at)?.comment;

  /// The comment the file wrote before the move at [at], how a variation is
  /// introduced. Nothing edits it; it is shown so a note is not invisible.
  String? startingCommentAt(NodePath at) => tree?.nodeAt(at)?.startingComment;

  /// Reads [ref] through the store, so the session holds the revision every
  /// later save is checked against.
  /// [game] opens one game of the file as the whole document, which is what
  /// a study chapter is; null merges its games. Another chapter of the same
  /// file is another [open], so the draft of the one being left goes to disk
  /// first, exactly as it does when another file is opened.
  Future<OpenResult> open(ChapterRef ref, {int? game}) async {
    final ticket = ++_opens;
    // A rename, move or delete of the document open now may still be running,
    // with a draft waiting behind it. That draft belongs to the file it was
    // typed into, so it goes out first — before this document takes the saver
    // over, and before the read below, which must not answer with text older
    // than the write still on its way.
    await _saver.flush();
    if (_disposed || ticket != _opens) return const OpenOvertaken();
    final read = await readDocument(_store, ref, game: game);
    if (_disposed || ticket != _opens) return const OpenOvertaken();
    switch (read) {
      case DocumentShown(:final chapter, :final view, :final revision):
        _show(chapter, ref, revision, read.readOnly, view: view);
        return const DocumentOpened();
      case DocumentUnread(:final reason):
        log.w('open ${ref.path}', reason);
        return OpenFailed(reason);
    }
  }

  /// Throws the draft away and takes what is on disk: how a conflict ends
  /// when the user decides the other version wins.
  Future<OpenResult> reloadFromDisk() async {
    final ref = _source;
    if (ref == null) return const OpenOvertaken();
    return open(ref, game: game);
  }

  /// The open document was renamed or moved: the same file with the same
  /// bytes, so only the name shown and the file saves go to change. A file
  /// moved takes the chapter of it that is open along.
  void relocated(ChapterRef ref) {
    final chapter = _chapter;
    final source = _source;
    if (source == null || chapter == null) return;
    final moved = ref.section == null && source.section != null
        ? source.inFile(ref.path)
        : ref;
    _file = (ref: moved, readOnly: _readOnly);
    _shown = (chapter: renamedChapter(chapter, moved.name), view: _view);
    _saver.relocated(moved);
    notifyListeners();
  }

  /// The open document was deleted, so the analysis board comes up rather
  /// than a chapter whose file is now in recovery.
  void closed() {
    if (_source == null) return;
    _opens++;
    _saver.closed();
    _showBoard();
  }

  /// The analysis board as it was left or, given [board], [board] in its
  /// place, once the file that was up has its last words written, as
  /// opening another file would.
  Future<void> showAnalysisBoard([Chapter? board]) async {
    if (board == null && isScratch) return;
    final ticket = ++_opens;
    if (!isScratch) await _saver.flush();
    if (_disposed || ticket != _opens) return;
    _saver.closed();
    if (board != null) _board.restart(board);
    _showBoard();
  }

  void _showBoard() {
    _shown = (chapter: _board.chapter, view: null);
    _file = null;
    _refused = null;
    _shownTo = null;
    _flipped = false;
    _cursor.value = _board.cursor;
    notifyListeners();
  }

  /// Puts the game at [index] of the open file on the board, without reading
  /// the file again: every game is already in hand, and a viewer walks them
  /// one after another. Only a document that shows one game at a time can
  /// do this; a merged chapter has no other game to show.
  ///
  /// The draft, if one is waiting, stays where it is. It belongs to the
  /// file, not to the game that was on the board when it was typed.
  void showGame(int index) {
    final chapter = _chapter;
    if (chapter == null || chapter.game == null) return;
    if (index < 0 || index >= chapter.lines.length) return;
    if (index == chapter.game) return;
    _shown = (
      chapter: withLines(chapter, chapter.lines, game: index),
      view: null,
    );
    _shownTo = null;
    _clearRefusal();
    _cursor.value = const NodePath.root();
    notifyListeners();
  }

  /// Moves the cursor; a path not in the tree is ignored.
  void goTo(NodePath path) {
    final tree = this.tree;
    if (tree == null || path == cursor) return;
    if (!path.isRoot && tree.nodeAt(path) == null) return;
    if (_shownTo case final limit? when !limit.startsWith(path)) return;
    _cursor.value = path;
  }

  void forward() => goTo(cursor.mainChild);

  void back() => goTo(cursor.parent);

  void toStart() => goTo(const NodePath.root());

  /// Steps into the first variation that branches off where the cursor is:
  /// the move played instead of the main continuation. Whether there was
  /// one to step into.
  bool enterVariation() {
    final variation = cursor.child(1);
    if (tree?.nodeAt(variation) == null) return false;
    goTo(variation);
    return cursor == variation;
  }

  /// Back out of the variation the cursor is in, to the move of the line
  /// it branches from. Whether the cursor was in one.
  bool leaveVariation() {
    final branch = cursor.branchPoint;
    if (branch == null) return false;
    goTo(branch);
    return cursor == branch;
  }

  void toEnd() {
    final tree = this.tree;
    if (tree != null) goTo(tree.endOfLineFrom(cursor));
  }

  /// Plays [uci] from the cursor and follows it. A move already in the tree
  /// only moves the cursor; a new one is written into the chapter and saved.
  /// An illegal move is ignored — the board offers legal moves only — and one
  /// the chapter comes back without is logged rather than saved.
  void playMove(String uci) {
    final chapter = _chapter;
    if (chapter == null || _shownTo != null) return;
    // A move the chapter already holds writes nothing, so following it is
    // reading: a file this app may not write still shows its own lines.
    final here = edits.playedAlready(chapter, at: cursor, uci: uci);
    if (here != null) {
      _cursor.value = here;
      return;
    }
    if (_refuseWhenReadOnly()) return;
    switch (edits.addMove(chapter, at: cursor, uci: uci)) {
      case edits.MoveIllegal():
        return;
      case edits.MoveRefused(:final reason):
        log.w('move ${_source?.path}', reason);
        _refused = const LineNotWhole();
        notifyListeners();
        return;
      case edits.MoveNotWritten():
        log.e('move ${_source?.path}', 'the chapter came back without $uci');
        _refused = const MoveLost();
        notifyListeners();
        return;
      case edits.MoveAdded(chapter: final edited, :final path, :final written):
        _clearRefusal();
        if (!identical(edited, chapter)) _replace(edited, written);
        _cursor.value = path;
        notifyListeners();
    }
  }

  /// Writes [text] as the comment on the move at [at], or as the chapter's
  /// introduction when [at] is the root. The path is the caller's, not the
  /// cursor's, so words typed under one move cannot land on another when the
  /// cursor moves first. Text that would leave the file as it is changes
  /// nothing. A game reading could not finish cannot take the comment, and
  /// neither can words a PGN file has no way to hold; then nothing is
  /// written and [refusedEdit] says so.
  void setComment(NodePath at, String? text) => _commentEdit(
    'comment',
    (chapter) => edits.setComment(chapter, at: at, text: text),
    quietWhenSame: true,
  );

  /// Puts the glyph [nag] on the move at [at] in place of the one it had, or
  /// takes it away when [nag] is null: the six marks a reader prints after a
  /// move, and nothing else about it.
  void setGlyph(NodePath at, int? nag) => _commentEdit(
    'glyph',
    (chapter) => edits.setGlyph(chapter, at: at, nag: nag),
  );

  /// Puts the bare token [marker] on the move at [at], or takes it away. A
  /// marker says something about the move rather than to the reader — a quiz
  /// starts here — so the words on it are left alone; everything else is a
  /// comment edit, with the same games written and the same refusals.
  void setMarker(NodePath at, String marker, {required bool on}) =>
      _commentEdit(
        'mark $marker in',
        (chapter) => edits.setMarker(chapter, at: at, marker: marker, on: on),
      );

  /// Makes a comment, glyph or marker edit, named [what] in the log. One
  /// that changes nothing is [quietWhenSame] unless it clears a refusal.
  void _commentEdit(
    String what,
    edits.CommentResult Function(Chapter chapter) edit, {
    bool quietWhenSame = false,
  }) {
    final chapter = _chapter;
    if (chapter == null || _refuseWhenReadOnly()) return;
    final hadRefusal = _refused != null;
    switch (edit(chapter)) {
      case final edits.CommentRefused refusal:
        log.w('$what ${_source?.path}', refusalDetail(refusal));
        _refused = refusalOf(refusal);
      case edits.CommentWritten(chapter: final edited, :final written):
        _clearRefusal();
        if (!identical(edited, chapter)) {
          _replace(edited, written);
        } else if (quietWhenSame && !hadRefusal) {
          return;
        }
    }
    notifyListeners();
  }

  /// Whether this document opened to read, in which case the edit does not
  /// happen and the screen says why again.
  bool _refuseWhenReadOnly() {
    final reason = _readOnly;
    if (reason == null) return false;
    _refused = NotEditable(reason);
    notifyListeners();
    return true;
  }

  /// Forgets the last refusal, except the standing one: a document opened to
  /// read says so until it is closed.
  void _clearRefusal() {
    final reason = _readOnly;
    _refused = reason == null ? null : NotEditable(reason);
  }

  /// Puts the file back as it was before the last edit and shows what came
  /// back, on the chapter it was on. A refused undo leaves the document and
  /// the history alone and says so.
  Future<UndoResult> undo() async {
    if (isScratch) return _undoOnBoard();
    final ref = _source;
    if (ref == null) return const UndoRefused();
    final ticket = _opens;
    final result = await _saver.undo();
    if (_disposed || ticket != _opens) return const UndoRefused();
    if (result case Restored(:final text)) {
      final showing = showingGameText(_chapter);
      final (:file, :view) = await readShown(ref, text, game: game);
      if (_disposed || ticket != _opens) return const UndoRefused();
      final restored = view?.chapter ?? showingGame(file, showing);
      final before = _chapter?.tree;
      _shown = (chapter: restored, view: view);
      _cursor.value = before == null
          ? const NodePath.root()
          : samePathIn(before, restored.tree, cursor);
      notifyListeners();
    }
    return result;
  }

  /// The analysis board as it was before its last edit.
  UndoResult _undoOnBoard() {
    final before = _chapter;
    final restored = _board.takeBack();
    if (restored == null || before == null) return const UndoRefused();
    _shown = (chapter: restored, view: null);
    _cursor.value = samePathIn(before.tree, restored.tree, cursor);
    notifyListeners();
    return Restored(writeChapter(restored));
  }

  void _show(
    Chapter chapter,
    ChapterRef ref,
    Revision revision,
    String? readOnly, {
    SectionView? view,
  }) {
    // The analysis board is put aside as it is, to be gone back to.
    if (_chapter case final board? when isScratch) {
      _board
        ..chapter = board
        ..cursor = cursor;
    }
    _shown = (chapter: chapter, view: view);
    _file = (ref: ref, readOnly: readOnly);
    _flipped = false;
    _shownTo = null;
    _refused = readOnly == null ? null : NotEditable(readOnly);
    _saver.opened(ref, revision, readOnly: readOnly);
    _cursor.value = const NodePath.root();
    notifyListeners();
  }

  /// Shows [edited] and puts it on disk, saying which games the edit wrote.
  /// The scope is what the edit reported, never what the text turned out to
  /// look like: that would agree with the text, and the store would have
  /// nothing to refuse.
  void _replace(Chapter edited, GamesWritten written) {
    if (_onBoard(edited)) return;
    final before = _chapter!;
    _land(
      landing(
        before,
        _view,
        edited,
        GamesArranged.of(written, before: before.lines.length),
        written: written,
      ),
    );
  }

  /// Shows what [edit] made of the open chapter and writes the games it says
  /// it wrote. Answers why it did not happen, or null when it did.
  ///
  /// Public, because a mode owns edits of its own — a study's chapters are
  /// the file's games — and they go to disk through this one path rather
  /// than through a second writer. These edits move and remove whole games,
  /// so the cursor is followed by the moves it was on rather than by its
  /// path, which after a rearrangement would name somebody else's move; an
  /// edit that changed which game is the chapter moves the board with it.
  String? apply(edits.ChapterEdit Function(Chapter chapter) edit) {
    final chapter = _chapter;
    if (chapter == null) return 'there is nothing open to edit';
    if (_refuseWhenReadOnly()) return _readOnly;
    switch (edit(chapter)) {
      case edits.ChapterUnchanged():
        return null;
      case edits.ChapterEditRefused(:final reason):
        return _editRefused(reason);
      case edits.ChapterEdited(chapter: final edited, :final games):
        if (!_onBoard(edited)) {
          final reason = _land(landing(chapter, _view, edited, games));
          if (reason != null) return reason;
        }
        _clearRefusal();
        _cursor.value = samePathIn(chapter.tree, _chapter!.tree, cursor);
    }
    notifyListeners();
    return null;
  }

  /// Where the games at [games] of the open chapter sit in its file: the
  /// same indexes when the chapter is the whole file.
  Set<int> placesInFile(Set<int> games) => _view?.placesOf(games) ?? games;

  /// Makes [edit] to the whole file the open chapter is in — a course
  /// file's chapters named, renamed, taken out — through the one path every
  /// edit takes. [section] is the chapter to show after it, when the edit
  /// renamed the open one. Answers why it did not happen, or null.
  String? applyToFile(
    edits.ChapterEdit Function(Chapter file) edit, {
    String? section,
  }) {
    final view = _view;
    if (view == null) return apply(edit);
    if (_refuseWhenReadOnly()) return _readOnly;
    switch (edit(view.file)) {
      case edits.ChapterUnchanged():
        return null;
      case edits.ChapterEditRefused(:final reason):
        return _editRefused(reason);
      case edits.ChapterEdited(chapter: final edited, :final games):
        _clearRefusal();
        final before = view.chapter.tree;
        _land(fileLanding(view.file, edited, games, section ?? view.section));
        _cursor.value = samePathIn(before, _chapter!.tree, cursor);
    }
    notifyListeners();
    return null;
  }

  /// Takes [edited] in memory when the analysis board is up, keeping the
  /// version it replaces for undo; nothing is written anywhere. False when
  /// a file is up and the edit is the saver's to write.
  bool _onBoard(Chapter edited) {
    final before = _chapter;
    if (!isScratch || before == null) return false;
    _board.remember(before);
    _shown = (chapter: edited, view: null);
    return true;
  }

  String _editRefused(String reason) {
    log.w('edit ${_source?.path}', reason);
    _refused = EditNotWritten(reason);
    notifyListeners();
    return reason;
  }

  /// Writes [landed] and shows what it says to show, following a course
  /// file's chapter to the one shown. Answers why nothing was written, or
  /// null.
  String? _land(Landing? landed) {
    if (landed == null) {
      return _editRefused('a new line could not be given its chapter name');
    }
    _saver.save(landed.text, landed.scope);
    _shown = (chapter: landed.chapter, view: landed.view);
    final source = _source!;
    final view = landed.view;
    if (view == null || view.section == source.section) return null;
    final moved = ChapterRef.at(source.path, section: view.section);
    _file = (ref: moved, readOnly: _readOnly);
    _saver.relocated(moved);
    return null;
  }

  /// Writes the draft on screen beside its file as `<name>.pgn`, replacing
  /// nothing. A copy changes nothing in the session, so nothing goes stale:
  /// whatever the user opened meanwhile, the answer is about the file they
  /// asked for.
  ///
  /// A document that can still take words keeps the session; one frozen by a
  /// stopped save, or that this app may not write, hands it over, because the
  /// copy is the only place those words can go on being edited. A conflicted
  /// document keeps it: it can still be reloaded.
  Future<CopyResult> saveCopy(String name) async {
    final written = await copyAside(name);
    if (written is! CopySaved) return written;
    final ref = _source;
    final frozen = _saver.state is SaveStopped || _readOnly != null;
    if (ref == null || !frozen) return written;
    final path = p.join(p.dirname(ref.path), written.name);
    final opened = await open(ChapterRef.at(path), game: game);
    return CopySaved(written.name, nowEditing: opened is DocumentOpened);
  }

  /// Writes the words on screen beside their file and leaves the session
  /// where it is, which is what the question on the way out asks for: the
  /// user is going somewhere else, so the copy is not what they want open.
  Future<CopyResult> copyAside(String name) async {
    final ref = _source;
    final chapter = _chapter;
    if (ref == null || chapter == null) {
      return const CopyFailed('there is nothing open to copy');
    }
    return _saver.copyAside(chapter, beside: ref, name: name);
  }

  @override
  void dispose() {
    _disposed = true;
    _cursor.dispose();
    super.dispose();
  }
}

/// What reading a document for the workspace came to: the chapter to show,
/// or the sentence saying why there is none.
sealed class DocumentRead {
  const DocumentRead();
}

final class DocumentShown extends DocumentRead {
  const DocumentShown({
    required this.chapter,
    required this.view,
    required this.revision,
    required this.readOnly,
  });

  /// What goes on the board: the file, one game of it, or one chapter of a
  /// course file.
  final Chapter chapter;

  /// Where that chapter sits in its file, for one chapter of a course file;
  /// null when the chapter is the whole file or one game of it.
  final SectionView? view;

  /// The revision every later save is checked against.
  final Revision revision;

  /// Why this app may not write the file, or null when it may.
  final String? readOnly;
}

final class DocumentUnread extends DocumentRead {
  const DocumentUnread(this.reason);

  final String reason;
}

/// Reads [ref] through [documents] as the chapter the workspace shows.
/// [game] reads one game of the file as the whole document, which is what a
/// study chapter is; null merges its games, or takes the chapter [ref]
/// names in a course file.
Future<DocumentRead> readDocument(
  store.PgnDocumentStore documents,
  ChapterRef ref, {
  int? game,
}) async {
  switch (await documents.open(ref)) {
    case store.Opened(:final text, :final revision, :final readOnly):
      final (:file, :view) = await readShown(ref, text, game: game);
      // A chapter the file does not have would otherwise open as every
      // game merged, which looks like a chapter and is not one.
      if (game != null && game >= file.lines.length) {
        return DocumentUnread('${ref.name} has no chapter ${game + 1}');
      }
      if (view != null && view.places.isEmpty) {
        return DocumentUnread('${ref.name} is no longer in its file');
      }
      return DocumentShown(
        chapter: view?.chapter ?? file,
        view: view,
        revision: revision,
        readOnly: readOnly,
      );
    case store.Absent():
      return DocumentUnread('${ref.name} is no longer on disk');
    case store.Unreadable(:final detail):
      return DocumentUnread('Could not read ${ref.name}: $detail');
  }
}

/// [text], the file [ref] names, as read for the workspace: the whole file
/// or the one [game] of it, and — for one chapter of a course file — where
/// that chapter sits in it.
Future<({Chapter file, SectionView? view})> readShown(
  ChapterRef ref,
  String text, {
  int? game,
}) async {
  final file = await readChapter(name: ref.fileName, text: text, game: game);
  return (file: file, view: game == null ? partOf(file, ref.section) : null);
}

/// An edit of the chapter on the board as its file takes it: the file's
/// text, the scope the store checks that text against, and the chapter to
/// show afterwards — with its [SectionView] when it is one chapter of a
/// course file.
typedef Landing = ({
  String text,
  EditScope scope,
  Chapter chapter,
  SectionView? view,
});

/// [edited], an edit of [before] placed by [games], as its file writes it.
///
/// A chapter that is its whole file is written as it is, with the ids the
/// edit would change pinned ([withIdsPinned]); [written], when the edit said
/// only which games it wrote, is the scope, which the pins do not widen —
/// they land on games the edit wrote anyway. A chapter of a course file
/// ([view]) goes back into its file ([spliced]) and the file is written.
///
/// Null when a game the edit added could not be given its chapter's name.
Landing? landing(
  Chapter before,
  SectionView? view,
  Chapter edited,
  GamesArranged games, {
  GamesWritten? written,
}) {
  if (view == null) {
    final pinned = withIdsPinned(before, edited, games);
    return (
      text: writeChapter(pinned.chapter),
      scope: written == null
          ? GamesRearranged(pinned.games)
          : GamesEdited(written),
      chapter: pinned.chapter,
      view: null,
    );
  }
  final back = spliced(view, edited, games);
  if (back == null) return null;
  return fileLanding(view.file, back.file, back.games, view.section);
}

/// [edited], an edit of the whole course [file] placed by [games], showing
/// its chapter [section] afterwards — or its first, when the edit left none
/// of that chapter's games.
Landing fileLanding(
  Chapter file,
  Chapter edited,
  GamesArranged games,
  String? section,
) {
  final edit = fileEdit(file, edited, games, section);
  return (
    text: writeChapter(edit.file),
    scope: GamesRearranged(edit.games),
    chapter: edit.shown.chapter,
    view: edit.shown,
  );
}

/// The analysis board as the [DocumentSession] keeps it: its moves, where
/// the user was on it, and its earlier versions for undo. No file holds any
/// of this, so it lives as long as the window, and a file opened in its
/// place leaves it here to go back to.
///
/// Only the session touches it; it is a part of the session's state, kept
/// apart so the session's own fields stay about the document that is up.
final class KeptBoard {
  KeptBoard(this.chapter);

  /// How many edits undo can take back.
  static const undoDepth = 200;

  /// The board as last seen: current while the board is up only after
  /// [DocumentSession] puts it aside.
  Chapter chapter;

  NodePath cursor = const NodePath.root();

  /// Earlier versions of the board, newest last.
  final _undo = <Chapter>[];

  bool get canUndo => _undo.isNotEmpty;

  /// A new board in place of this one, with the cursor at the end of its
  /// main line and nothing to undo.
  void restart(Chapter board) {
    chapter = board;
    cursor = board.tree.endOfLineFrom(const NodePath.root());
    _undo.clear();
  }

  /// [before] is the version an edit just replaced.
  void remember(Chapter before) {
    _undo.add(before);
    if (_undo.length > undoDepth) _undo.removeAt(0);
  }

  /// The version before the last edit, or null when there is none.
  Chapter? takeBack() => _undo.isEmpty ? null : _undo.removeLast();
}

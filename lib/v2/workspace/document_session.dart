import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../chess/fen.dart';
import '../chess/pgn/chapter.dart';
import '../chess/pgn/chapter_edit.dart' as edits;
import '../chess/pgn/chapter_edits.dart' as edits;
import '../chess/pgn/comment_edits.dart' as edits;
import '../chess/pgn/games_written.dart';
import '../chess/pgn/game_tree.dart';
import '../chess/pgn/tree_edit.dart';
import '../diagnostics/log.dart';
import '../storage/chapter_files.dart';
import '../storage/document_ref.dart';
import '../storage/edit_scope.dart';
import '../storage/pgn_document_store.dart' as store;
import 'copy_aside.dart';
import 'document_saver.dart';
import 'edit_refused.dart';
import 'save_state.dart';
import 'session_results.dart';

/// The document open in the workspace, where the user is in it, and the
/// edits they make to it.
///
/// Holds the chapter (an immutable value), the file it came from and the
/// cursor. The board, the move list and every panel derive what they show
/// from these; nothing else in the workspace keeps a copy of the tree, the
/// position or which file is open. Writing to disk belongs to the
/// [DocumentSaver] this session was given: an edit replaces the chapter and
/// hands the saver the new file text.
final class DocumentSession extends ChangeNotifier {
  DocumentSession(this._store, this._saver);

  final store.PgnDocumentStore _store;
  final DocumentSaver _saver;
  Chapter? _chapter;
  ChapterRef? _source;
  int? _game;
  String? _readOnly;
  NodePath _cursor = const NodePath.root();
  EditRefused? _refused;
  int _opens = 0;
  bool _disposed = false;

  Chapter? get chapter => _chapter;

  /// Why the last edit did not happen, or null when it did. A game reading
  /// could not finish keeps its own bytes and is never generated again, so
  /// an edit that would have to write it is refused, and so are words a PGN
  /// file cannot hold and every edit to a file this app may not write. The
  /// next edit that lands, and opening another document, clears this.
  EditRefused? get refusedEdit => _refused;

  /// Why this document cannot be written, or null when it can.
  String? get readOnly => _readOnly;

  /// The file the chapter was read from.
  ChapterRef? get source => _source;

  /// Which game of that file is on the board, or null when its games are
  /// merged. A repertoire chapter is the file; a study chapter is one game.
  int? get game => _chapter?.game;
  GameTree? get tree => _chapter?.tree;

  NodePath get cursor => _cursor;

  Fen get fen => tree?.fenAt(_cursor) ?? Fen.initial;

  /// The repertoire's side, or a study chapter's own orientation tag.
  Side get orientation => _chapter?.side ?? Side.white;

  /// The move the cursor is on; null at the root.
  MoveNode? get currentMove => tree?.nodeAt(_cursor);

  /// The comment on the move at [at], or the chapter's introduction at the
  /// root; machine tokens included.
  String? commentAt(NodePath at) =>
      at.isRoot ? tree?.rootComment : tree?.nodeAt(at)?.comment;

  /// The comment the file wrote before the move at [at], which is how a
  /// variation is introduced. Nothing edits it; it is shown so a note the
  /// file holds is not invisible.
  String? startingCommentAt(NodePath at) => tree?.nodeAt(at)?.startingComment;

  /// Reads [ref] through the store, so the session holds the revision every
  /// later save is checked against.
  /// [game] opens one game of the file as the whole document, which is what
  /// a study chapter is; null merges its games. Another chapter of the same
  /// file is another [open], so the draft of the one being left goes to disk
  /// first, exactly as it does when another file is opened.
  Future<OpenResult> open(ChapterRef ref, {int? game}) async {
    final ticket = ++_opens;
    _game = game;
    // A rename, move or delete of the document open now may still be running,
    // with a draft waiting behind it. That draft belongs to the file it was
    // typed into, so it goes out first — before this document takes the saver
    // over, and before the read below, which must not answer with text older
    // than the write still on its way.
    await _saver.flush();
    if (_disposed || ticket != _opens) return const OpenOvertaken();
    final read = await _store.open(ref);
    if (_disposed || ticket != _opens) return const OpenOvertaken();
    switch (read) {
      case store.Opened(:final text, :final revision, :final readOnly):
        final chapter = await readChapter(
          name: ref.name,
          text: text,
          game: game,
        );
        if (_disposed || ticket != _opens) return const OpenOvertaken();
        _show(chapter, ref, revision, readOnly);
        return const DocumentOpened();
      case store.Absent():
        return _openFailed(ref, '${ref.name} is no longer on disk');
      case store.Unreadable(:final detail):
        return _openFailed(ref, 'Could not read ${ref.name}: $detail');
    }
  }

  /// Throws the draft away and takes what is on disk: how a conflict ends
  /// when the user decides the other version wins.
  Future<OpenResult> reloadFromDisk() async {
    final ref = _source;
    if (ref == null) return const OpenOvertaken();
    return open(ref, game: _game);
  }

  /// The open document was renamed or moved: the same file with the same
  /// bytes, so only the name shown and the file later saves go to changes.
  void relocated(ChapterRef ref) {
    final chapter = _chapter;
    if (_source == null || chapter == null) return;
    _source = ref;
    _chapter = renamedChapter(chapter, ref.name);
    _saver.relocated(ref);
    notifyListeners();
  }

  /// The open document was deleted, so the workspace empties rather than
  /// showing a chapter whose file is now in recovery.
  void closed() {
    if (_source == null) return;
    _opens++;
    _chapter = null;
    _source = null;
    _game = null;
    _cursor = const NodePath.root();
    _refused = null;
    _saver.closed();
    notifyListeners();
  }

  /// Moves the cursor; a path that is not in the tree is ignored.
  void goTo(NodePath path) {
    final tree = this.tree;
    if (tree == null || path == _cursor) return;
    if (!path.isRoot && tree.nodeAt(path) == null) return;
    _cursor = path;
    notifyListeners();
  }

  void forward() => goTo(_cursor.mainChild);

  void back() => goTo(_cursor.parent);

  void toStart() => goTo(const NodePath.root());

  void toEnd() {
    final tree = this.tree;
    if (tree != null) goTo(tree.endOfLineFrom(_cursor));
  }

  /// Plays [uci] from the cursor and follows it. A move already in the tree
  /// only moves the cursor; a new one is written into the chapter and saved.
  /// An illegal move is ignored — the board offers legal moves only — and a
  /// move the chapter comes back without is logged rather than saved.
  void playMove(String uci) {
    final chapter = _chapter;
    if (chapter == null) return;
    // A move the chapter already holds writes nothing, so following it is
    // reading: a file this app may not write still shows its own lines, and
    // asking costs one move rather than a whole edited chapter.
    final here = edits.playedAlready(chapter, at: _cursor, uci: uci);
    if (here != null) {
      _cursor = here;
      notifyListeners();
      return;
    }
    if (_refuseWhenReadOnly()) return;
    switch (edits.addMove(chapter, at: _cursor, uci: uci)) {
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
        _cursor = path;
        if (!identical(edited, chapter)) _replace(edited, written);
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
  void setComment(NodePath at, String? text) {
    final chapter = _chapter;
    if (chapter == null) return;
    if (_refuseWhenReadOnly()) return;
    final hadRefusal = _refused != null;
    switch (edits.setComment(chapter, at: at, text: text)) {
      case final edits.CommentRefused refusal:
        log.w('comment ${_source?.path}', refusalDetail(refusal));
        _refused = refusalOf(refusal);
      case edits.CommentWritten(chapter: final edited, :final written):
        _clearRefusal();
        if (identical(edited, chapter)) {
          if (!hadRefusal) return;
        } else {
          _replace(edited, written);
        }
    }
    notifyListeners();
  }

  /// Puts the bare token [marker] on the move at [at], or takes it away.
  ///
  /// A marker says something about the move rather than to the reader — a
  /// quiz starts here — so the words on it are left alone. Everything else
  /// is a comment edit: the same games are written, the same refusals apply.
  void setMarker(NodePath at, String marker, {required bool on}) {
    final chapter = _chapter;
    if (chapter == null) return;
    if (_refuseWhenReadOnly()) return;
    switch (edits.setMarker(chapter, at: at, marker: marker, on: on)) {
      case final edits.CommentRefused refusal:
        log.w('mark $marker in ${_source?.path}', refusalDetail(refusal));
        _refused = refusalOf(refusal);
      case edits.CommentWritten(chapter: final edited, :final written):
        _clearRefusal();
        if (!identical(edited, chapter)) _replace(edited, written);
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
  /// back. A refused undo leaves the document and the history alone and says
  /// so: nothing happening is something the screen has to tell.
  Future<UndoResult> undo() async {
    final ref = _source;
    if (ref == null) return const UndoRefused();
    final ticket = _opens;
    final result = await _saver.undo();
    if (_disposed || ticket != _opens) return const UndoRefused();
    if (result case Restored(:final text)) {
      final restored = await readChapter(
        name: ref.name,
        text: text,
        game: _game,
      );
      if (_disposed || ticket != _opens) return const UndoRefused();
      final before = _chapter?.tree;
      _chapter = restored;
      _cursor = before == null
          ? const NodePath.root()
          : samePathIn(before, restored.tree, _cursor);
      notifyListeners();
    }
    return result;
  }

  /// Writes the draft beside the original as `<name>.pgn`, replacing
  /// nothing. A copy changes nothing here, so nothing about it goes stale:
  /// whatever the user opened while it was being written, the answer is
  /// about the file they asked for.
  Future<CopyResult> saveCopy(String name) async {
    final written = await copyAside(name);
    if (written is! CopySaved) return written;
    final ref = _source;
    // A document that can still take words keeps the session; one frozen by
    // a stopped save, or that this app may not write, hands it over, because
    // the copy is the only place those words can go on being edited. A
    // conflicted document keeps it: it can still be reloaded.
    final frozen = _saver.state is SaveStopped || _readOnly != null;
    if (ref == null || !frozen) return written;
    final path = p.join(p.dirname(ref.path), written.name);
    final opened = await open(ChapterRef.at(path), game: _game);
    return CopySaved(written.name, nowEditing: opened is DocumentOpened);
  }

  /// Writes the words on screen beside the original and leaves the session
  /// where it is, which is what the question on the way out asks for: the
  /// user is going somewhere else, so the copy is not what they want open.
  Future<CopyResult> copyAside(String name) async {
    final ref = _source;
    final chapter = _chapter;
    if (ref == null || chapter == null) {
      return const CopyFailed('there is nothing open to copy');
    }
    return copyChapterAside(_store, chapter, beside: ref, name: name);
  }

  void _show(
    Chapter chapter,
    ChapterRef ref,
    Revision revision,
    String? readOnly,
  ) {
    _chapter = chapter;
    _source = ref;
    _cursor = const NodePath.root();
    _readOnly = readOnly;
    _refused = readOnly == null ? null : NotEditable(readOnly);
    _saver.opened(ref, revision, readOnly: readOnly);
    notifyListeners();
  }

  /// Shows [edited] and puts it on disk, saying which games the edit wrote.
  /// The scope is what the edit reported, never what the new text turned out
  /// to look like: a scope worked out from the text would agree with the
  /// text, and the store would have nothing to refuse.
  void _replace(Chapter edited, GamesWritten written) {
    _chapter = edited;
    _saver.save(writeChapter(edited), GamesEdited(written));
  }

  OpenFailed _openFailed(ChapterRef ref, String reason) {
    log.w('open ${ref.path}', reason);
    return OpenFailed(reason);
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
        log.w('edit ${_source?.path}', reason);
        _refused = EditNotWritten(reason);
        notifyListeners();
        return reason;
      case edits.ChapterEdited(chapter: final edited, :final games):
        _clearRefusal();
        _chapter = edited;
        _game = edited.game;
        _cursor = samePathIn(chapter.tree, edited.tree, _cursor);
        _saver.save(writeChapter(edited), GamesRearranged(games));
    }
    notifyListeners();
    return null;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

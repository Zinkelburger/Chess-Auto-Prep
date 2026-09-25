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
import '../chess/pgn/tree_edit.dart';
import '../chess/pv_text.dart';
import '../diagnostics/log.dart';
import '../storage/chapter_files.dart';
import '../storage/document_ref.dart';
import '../storage/edit_scope.dart' show withReferences;
import '../storage/reference_change.dart';
import '../storage/pgn_document_store.dart' as store;
import 'comment_line.dart';
import 'document_saver.dart';
import 'document_access.dart';
import 'document_projection.dart';
import 'document_history.dart';
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
    _cursor.addListener(closeCommentLine);
  }

  final store.PgnDocumentStore _store;
  final DocumentSaver _saver;
  final access = DocumentAccess();

  /// The persisted input behind the shown draft; training must retain this
  /// native observation rather than adopt whichever file later has its path.
  Revision? get persistedRevision => _saver.revision;
  Revision? get trainingSourceRevision => _saver.trainingSourceRevision;
  store.Receipt? get persistedChange => _saver.lastReceipt;
  Listenable get persistedChanges => _saver;

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
  final _commentLine = ValueNotifier<CommentLine?>(null);
  EditRefused? _refused;
  NodePath? _shownTo;
  bool _flipped = false;
  int _opens = 0;

  /// The ticket of the open, or the change to the analysis board, still on
  /// its way; null when none is. An undo is not made meanwhile: the saver
  /// goes to another file when it lands, and the undo would put back the
  /// file being left and could show it under the one arriving.
  int? _opening;

  /// Whether an undo is reading the version it put back. Edits wait for it:
  /// one made to the chapter on screen until then would be written over
  /// that version.
  bool _restoring = false;

  bool _disposed = false;

  /// Edits to the open file shown but not written; null when there are none.
  HeldEdits? _held;

  /// Whether an edit to a file is kept in memory rather than written: on in
  /// the PGN Viewer, where moves played on the board are for looking, off
  /// in the builder, which saves every edit as it is made. Once one edit is
  /// held, the rest join it until [keepHeld] or [discardHeld], whichever
  /// mode is up: a file half on disk and half in memory could not be undone
  /// or thrown away as one.
  bool get holdsEdits => _holdsEdits;
  bool _holdsEdits = false;
  set holdsEdits(bool on) {
    if (on == _holdsEdits) return;
    _holdsEdits = on;
    notifyListeners();
  }

  /// Whether the file on the board has edits that are not on disk.
  bool get hasHeldEdits => _held != null;

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
  /// file, from memory on the analysis board and for held edits.
  bool get canUndo =>
      isScratch ? _board.canUndo : _held != null || _saver.canUndo;

  /// The file the chapter was read from, and which game of it is on the
  /// board — null when its games are merged. A repertoire chapter is the
  /// file; a study chapter is one game.
  ChapterRef? get source => _source;

  int? get game => _chapter?.game;
  GameTree? get tree => _chapter?.tree;

  NodePath get cursor => _cursor.value;

  /// Notifies when the cursor moves, and only then.
  ValueListenable<NodePath> get cursorListenable => _cursor;

  /// Notifies just before another document or game goes up in place of the
  /// one on the board, or the one on the board is renamed, while it is still
  /// the session's: a view holding words typed for it hands them over now,
  /// while the paths it holds still name the moves they were typed at.
  Listenable get leaving => _leaving;
  final _leaving = _Leaving();

  /// Notifies for a cursor move and for everything the session notifies
  /// for: what a view of the position, rather than of the document, needs.
  /// One object for the session's life, so a widget rebuilt with it keeps
  /// its subscription.
  late final Listenable anyChange = Listenable.merge([
    this,
    _cursor,
    _commentLine,
  ]);

  Fen get fen => tree?.fenAt(cursor) ?? Fen.initial;

  /// A line written in a comment that the board shows in place of the
  /// cursor's position; null while it shows the cursor's. Nothing of it is
  /// in the file: the cursor stays on the move the comment belongs to, the
  /// board takes no moves, and moving in the file, or any change to it,
  /// puts the board back on the file.
  ValueListenable<CommentLine?> get commentLine => _commentLine;

  /// The position on the board: the comment line's while one is shown.
  Fen get boardFen => _commentLine.value?.fen ?? fen;

  /// The move that reached [boardFen], as UCI, for the highlight.
  String? get boardLastMove => _commentLine.value?.move.uci ?? currentMove?.uci;

  /// Reads the line written in a comment on the move at [from], as far as
  /// its move at [at]. When the file already plays those moves from there,
  /// the cursor follows them instead; otherwise the board shows the line
  /// and the file is left as it is.
  void showCommentLine(NodePath from, List<PvMove> moves, int at) {
    final tree = this.tree;
    if (tree == null || _shownTo != null) return;
    if (!from.isRoot && tree.nodeAt(from) == null) return;
    final inFile = pathPlaying(tree, from, moves.take(at + 1));
    if (inFile != null) {
      closeCommentLine();
      _cursor.value = inFile;
      return;
    }
    _cursor.value = from;
    _commentLine.value = CommentLine(from: from, moves: moves, at: at);
  }

  /// Puts the board back on the file's position.
  void closeCommentLine() => _commentLine.value = null;

  /// Whatever changes the document, or how it is shown, puts the board back
  /// on the file: the line was read from a position that may be gone.
  @override
  void notifyListeners() {
    closeCommentLine();
    super.notifyListeners();
  }

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
  ///
  /// Words the file has not taken when this is called are left with the
  /// document: whoever calls it has asked the user about them first, or is
  /// throwing them away because the user said to.
  Future<OpenResult> open(ChapterRef ref, {int? game}) {
    final ticket = ++_opens;
    return _switching(ticket, () => _opened(ref, game, ticket));
  }

  /// A newer navigation intent supersedes a read even if it stays here.
  void cancelOpening() {
    _opens++;
    _opening = null;
  }

  /// Runs [change], which puts another document up, with undo held off
  /// until it is over.
  Future<T> _switching<T>(int ticket, Future<T> Function() change) async {
    _opening = ticket;
    try {
      return await change();
    } finally {
      if (_opening == ticket) _opening = null;
    }
  }

  Future<OpenResult> _opened(ChapterRef ref, int? game, int ticket) async {
    // A rename, move or delete of the document open now may still be running,
    // with a draft waiting behind it. That draft belongs to the file it was
    // typed into, so it goes out first — before this document takes the saver
    // over, and before the read below, which must not answer with text older
    // than the write still on its way.
    await _saver.flush();
    if (_disposed || ticket != _opens) return const OpenOvertaken();
    await access.settled(ref.path);
    if (_disposed || ticket != _opens) return const OpenOvertaken();
    final version = access.versionOf(ref.path);
    final leftAsIs = !_saver.settled;
    final read = await readDocument(_store, ref, game: game);
    if (_disposed || ticket != _opens) return const OpenOvertaken();
    if (access.versionOf(ref.path) != version)
      return _opened(ref, game, ticket);
    final DocumentShown shown;
    switch (read) {
      case DocumentUnread(:final reason):
        log.w('open ${ref.path}', reason);
        return OpenFailed(reason);
      case DocumentShown():
        shown = read;
    }
    _leaving.announce();
    if (!leftAsIs && !_saver.settled) {
      // The document being left could still be edited while this one was
      // read, and nobody was asked about those words: they go to its file
      // before the saver is handed over. Words the file will not take keep
      // that document up, where the screen says why.
      final into = _saver.documentPath;
      await _saver.flush();
      if (_disposed || ticket != _opens || !_saver.settled) {
        return const OpenOvertaken();
      }
      // Written into the file being opened, they are newer than the text
      // read from it.
      if (into == ref.path) return _opened(ref, game, ticket);
    }
    if (access.versionOf(ref.path) != version)
      return _opened(ref, game, ticket);
    _show(shown.chapter, ref, shown.revision, shown.readOnly, view: shown.view);
    return const DocumentOpened();
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
    final source = _source;
    if (source == null || _chapter == null) return;
    _leaving.announce();
    final chapter = _chapter!;
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
    _leaving.announce();
    _opens++;
    _saver.closed();
    _showBoard();
  }

  /// The analysis board as it was left or, given [board], [board] in its
  /// place, once the file that was up has its last words written, as
  /// opening another file would. Whether the board is up: false when
  /// another document was asked for meanwhile, or the session went.
  Future<bool> showAnalysisBoard([Chapter? board]) async {
    if (_disposed) return false;
    if (board == null && isScratch) return true;
    // Before the flush, which then writes what the words make of the file.
    _leaving.announce();
    final ticket = ++_opens;
    if (!isScratch) await _switching(ticket, _saver.flush);
    if (_disposed || ticket != _opens) return false;
    _saver.closed();
    if (board != null) _board.restart(board);
    _showBoard();
    return true;
  }

  void _showBoard() {
    _held = null;
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
    if (!_isAnotherGame(index)) return;
    _leaving.announce();
    // The words handed over are in the chapter now, so it is read again.
    if (!_isAnotherGame(index)) return;
    final chapter = _chapter!;
    _shown = (chapter: withGame(chapter, index), view: null);
    _shownTo = null;
    _clearRefusal();
    _cursor.value = const NodePath.root();
    notifyListeners();
  }

  /// Whether [index] is another game of a file shown one game at a time.
  bool _isAnotherGame(int index) {
    final chapter = _chapter;
    if (chapter == null || chapter.game == null) return false;
    return index >= 0 && index < chapter.lines.length && index != chapter.game;
  }

  /// Moves the cursor; a path not in the tree is ignored. Going to the move
  /// the cursor is already on still puts the board back on the file.
  void goTo(NodePath path) {
    final tree = this.tree;
    if (path == cursor) closeCommentLine();
    if (tree == null || path == cursor) return;
    if (!path.isRoot && tree.nodeAt(path) == null) return;
    if (_shownTo case final limit? when !limit.startsWith(path)) return;
    _cursor.value = path;
  }

  /// The next move of the file, or of the comment line on the board.
  void forward() {
    if (_commentLine.value case final line?) {
      if (line.at + 1 < line.moves.length) {
        _commentLine.value = line.atMove(line.at + 1);
      }
      return;
    }
    goTo(cursor.mainChild);
  }

  /// The move before in the file; while a comment line is on the board, its
  /// move before, and from its first move back to the file.
  void back() {
    if (_commentLine.value case final line?) {
      _commentLine.value = line.at == 0 ? null : line.atMove(line.at - 1);
      return;
    }
    goTo(cursor.parent);
  }

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
    // The board shows a comment's line, not the cursor's position.
    if (_commentLine.value != null) return;
    // A move the chapter already holds writes nothing, so following it is
    // reading: a file this app may not write still shows its own lines.
    final here = edits.playedAlready(chapter, at: cursor, uci: uci);
    if (here != null) {
      _cursor.value = here;
      return;
    }
    if (_editBlocked() != null) return;
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
    if (chapter == null || _editBlocked() != null) return;
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

  /// Why an edit may not happen now, or null when it may: the document
  /// opened to read, or an undo is still reading the version it put back.
  /// The screen says why again either way.
  String? _editBlocked() {
    if (_readOnly case final reason?) {
      _refused = NotEditable(reason);
      notifyListeners();
      return reason;
    }
    if (_saver.referencesPending) {
      return _editRefused(
        'the chapter and its references need to finish saving',
      );
    }
    if (_restoring) {
      return _editRefused('an undo is still putting the chapter back');
    }
    return null;
  }

  /// Forgets the last refusal, except the standing one: a document opened to
  /// read says so until it is closed.
  void _clearRefusal() {
    final reason = _readOnly;
    _refused = reason == null ? null : NotEditable(reason);
  }

  /// Puts the file back as it was before the last edit and shows what came
  /// back, on the chapter it was on. A refused undo leaves the document and
  /// the history alone and says so. One that lands after the user went to
  /// another document is still what its file holds; the document on screen
  /// now is not touched.
  Future<UndoResult> undo() async {
    if (isScratch) return _undoOnBoard();
    if (_held != null) return _undoHeld();
    final ref = _source;
    if (ref == null || _opening != null || _restoring) {
      return const UndoRefused();
    }
    final guard = _saver.writeGuard?.call();
    final ticket = _opens;
    try {
      final problem = await guard?.pauseForWrite();
      if (problem != null) return UndoRefused(problem);
      if (ticket != _opens || ref != _source) {
        return const UndoRefused('The open document changed before undo.');
      }
      final result = await _saver.undo();
      if (result case Restored(:final text) when _stillOn(ref, ticket)) {
        await _showRestored(_source!, ticket, text);
      }
      return result;
    } on Object catch (error) {
      return UndoRefused(error.toString());
    } finally {
      guard?.resumeAfterWrite();
    }
  }

  /// Retries a failed publication, including restoring the displayed chapter
  /// when the publication was an undo whose acknowledgement was lost.
  Future<void> retrySave() async {
    if (_saver.retryNeedsUndo) {
      await undo();
    } else {
      await _saver.flush();
    }
  }

  /// Whether the document [ref], up when [ticket] was taken, is still the
  /// one on screen: nothing was asked for in its place — it may have been
  /// renamed — or what was asked for has not arrived, and may never when
  /// its read fails. Either way the screen must show what its file holds.
  bool _stillOn(ChapterRef ref, int ticket) =>
      !_disposed && (ticket == _opens || _source == ref);

  /// Shows [text], the version an undo put back into the file of [ref],
  /// on the chapter the user was on: the game they were looking at, found
  /// by its bytes, and a course file's chapter found by its games when the
  /// undo took back the name they were given.
  Future<void> _showRestored(ChapterRef ref, int ticket, String text) async {
    final places = _view?.places ?? const <int>[];
    _restoring = true;
    final ({Chapter file, SectionView? view}) read;
    try {
      read = await readShown(ref, text, game: game);
    } finally {
      _restoring = false;
    }
    if (!_stillOn(ref, ticket)) return;
    // Renamed while it was read: read again, so it shows its new name.
    if (_source != ref) return _showRestored(_source!, ticket, text);
    final view = read.view;
    final shown = view == null
        ? (
            chapter: gameAfterUndo(read.file, showingGameText(_chapter)),
            view: null,
          )
        : chapterAfterUndo(read.file, view, places);
    final before = _chapter?.tree;
    _shown = shown;
    _follow(shown.view);
    // A refusal was about the version the undo replaced.
    _clearRefusal();
    _cursor.value = before == null
        ? const NodePath.root()
        : samePathIn(before, shown.chapter.tree, cursor);
    notifyListeners();
  }

  /// The file as it was before the last held edit; the first one taken
  /// back leaves the file as it is on disk, with nothing held.
  UndoResult _undoHeld() {
    final held = _held!;
    final before = _shown!;
    final restored = held.takeBack();
    if (held.isEmpty) _held = null;
    _showHeld(before.chapter, restored);
    return Restored(writeChapter(restored.chapter));
  }

  /// Writes the held edits to the file, as one save.
  void keepHeld() {
    final held = _held;
    if (held == null) return;
    _held = null;
    // An edit that gave the file a chapter took the board to it, and the
    // saver waited for the edits to be kept before going there too.
    if (_source case final ref?) _saver.relocated(ref);
    _saver.save(held.text, held.scope);
    notifyListeners();
  }

  /// Throws the held edits away and shows the file as it is on disk.
  void discardHeld() {
    final held = _held;
    if (held == null) return;
    _leaving.announce();
    final before = _shown!.chapter;
    _held = null;
    _showHeld(before, held.original);
  }

  void _showHeld(Chapter before, ShownDocument shown) {
    _shown = shown;
    final source = _source;
    if (source != null && shown.view?.section != source.section) {
      _file = (
        ref: ChapterRef.at(source.path, section: shown.view?.section),
        readOnly: _readOnly,
      );
    }
    _clearRefusal();
    _cursor.value = samePathIn(before.tree, shown.chapter.tree, cursor);
    notifyListeners();
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
    _held = null;
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
  String? apply(
    edits.ChapterEdit Function(Chapter chapter) edit, {
    ReferenceChanges? references,
  }) {
    final chapter = _chapter;
    if (chapter == null) return 'there is nothing open to edit';
    if (_editBlocked() case final reason?) return reason;
    switch (edit(chapter)) {
      case edits.ChapterUnchanged():
        return null;
      case edits.ChapterEditRefused(:final reason):
        return _editRefused(reason);
      case edits.ChapterEdited(chapter: final edited, :final games):
        if (!_onBoard(edited)) {
          final reason = _land(
            _referenceLanding(
              landing(chapter, _view, edited, games),
              references,
            ),
          );
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
    ReferenceChanges? references,
  }) {
    final view = _view;
    if (view == null) return apply(edit, references: references);
    if (_editBlocked() case final reason?) return reason;
    switch (edit(view.file)) {
      case edits.ChapterUnchanged():
        return null;
      case edits.ChapterEditRefused(:final reason):
        return _editRefused(reason);
      case edits.ChapterEdited(chapter: final edited, :final games):
        _clearRefusal();
        final before = view.chapter.tree;
        final landed = fileLanding(
          view.file,
          edited,
          games,
          section ?? view.section,
        );
        _land(_referenceLanding(landed, references));
        _cursor.value = samePathIn(before, _chapter!.tree, cursor);
    }
    notifyListeners();
    return null;
  }

  Landing? _referenceLanding(Landing? landed, ReferenceChanges? references) =>
      references == null || landed == null
      ? landed
      : (
          text: landed.text,
          scope: withReferences(landed.scope, references),
          chapter: landed.chapter,
          view: landed.view,
        );

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
    if (_held case final held?) {
      held.add(_shown!, landed);
    } else if (_holdsEdits) {
      _held = HeldEdits(_shown!, landed);
    } else {
      _saver.save(landed.text, landed.scope);
    }
    _shown = (chapter: landed.chapter, view: landed.view);
    _follow(landed.view);
    return null;
  }

  /// The chapter on the board is now [view]'s. When that is another chapter
  /// of the open file than the one the session was on, the session and the
  /// saver follow it, under its name.
  void _follow(SectionView? view) {
    final source = _source!;
    if (view == null || view.section == source.section) return;
    final moved = ChapterRef.at(source.path, section: view.section);
    _file = (ref: moved, readOnly: _readOnly);
    // Held edits have not given the file that chapter yet: the saver goes
    // to it when they are kept.
    if (_held == null) _saver.relocated(moved);
  }

  /// Writes the draft on screen beside its file as `<name>.pgn`, replacing
  /// nothing; the answer is about the file the user asked for, whatever they
  /// opened meanwhile.
  ///
  /// A document that can still take words keeps the session; one frozen by a
  /// stopped save, or that this app may not write, hands it over, because the
  /// copy is the only place those words can go on being edited. A conflicted
  /// document keeps it: it can still be reloaded. So does a document the user
  /// has left, or opened another in place of, while the copy was written:
  /// the copy is of the one that was up, not of the one up now.
  Future<CopyResult> saveCopy(String name) async {
    final ticket = _opens;
    final ref = _source;
    final atGame = game;
    final written = await copyAside(name);
    if (written is! CopySaved || ref == null) return written;
    if (_disposed || ticket != _opens || _source != ref) return written;
    final frozen = _saver.state is SaveStopped || _readOnly != null;
    if (!frozen) return written;
    final path = p.join(p.dirname(ref.path), written.name);
    final opened = await open(ChapterRef.at(path), game: atGame);
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
    _commentLine.dispose();
    _leaving.dispose();
    super.dispose();
  }
}

/// [DocumentSession.leaving]: only the session says when it leaves.
final class _Leaving extends ChangeNotifier {
  void announce() => notifyListeners();
}

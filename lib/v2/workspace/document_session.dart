import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../chess/fen.dart';
import '../chess/pgn/chapter.dart';
import '../chess/pgn/chapter_edit.dart' as edits;
import '../chess/pgn/chapter_edits.dart' as edits;
import '../chess/pgn/chapter_sections.dart';
import '../chess/pgn/comment_edits.dart' as edits;
import '../chess/pgn/games_written.dart';
import '../chess/pgn/line_id_pins.dart';
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
  DocumentSession(this._store, this._saver);

  final store.PgnDocumentStore _store;
  final DocumentSaver _saver;
  Chapter? _chapter;

  /// The file and where the open chapter's games sit in it, when the open
  /// chapter is one of several a file holds by tag; null when it is the
  /// whole file. Edits are made to [_chapter] and put back into the file.
  SectionView? _view;
  ChapterRef? _source;
  String? _readOnly;
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

  void flip() {
    _flipped = !_flipped;
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
        // A chapter the file does not have would otherwise open as every
        // game merged, which looks like a chapter and is not one.
        if (game != null && game >= chapter.lines.length) {
          return _openFailed(ref, '${ref.name} has no chapter ${game + 1}');
        }
        final view = game == null ? _viewOf(chapter, ref) : null;
        if (view != null && view.places.isEmpty) {
          return _openFailed(ref, '${ref.name} is no longer in its file');
        }
        _view = view;
        _show(view?.chapter ?? chapter, ref, revision, readOnly);
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
    _source = moved;
    _chapter = renamedChapter(chapter, moved.name);
    _saver.relocated(moved);
    notifyListeners();
  }

  /// The open document was deleted, so the workspace empties rather than
  /// showing a chapter whose file is now in recovery.
  void closed() {
    if (_source == null) return;
    _opens++;
    _chapter = null;
    _view = null;
    _source = null;
    _refused = null;
    _shownTo = null;
    _saver.closed();
    _cursor.value = const NodePath.root();
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
    _chapter = withLines(chapter, chapter.lines, game: index);
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

  /// Puts the glyph [nag] on the move at [at] in place of the one it had, or
  /// takes it away when [nag] is null: the six marks a reader prints after a
  /// move, and nothing else about it.
  void setGlyph(NodePath at, int? nag) {
    final chapter = _chapter;
    if (chapter == null) return;
    if (_refuseWhenReadOnly()) return;
    switch (edits.setGlyph(chapter, at: at, nag: nag)) {
      case final edits.CommentRefused refusal:
        log.w('glyph ${_source?.path}', refusalDetail(refusal));
        _refused = refusalOf(refusal);
      case edits.CommentWritten(chapter: final edited, :final written):
        _clearRefusal();
        if (!identical(edited, chapter)) _replace(edited, written);
    }
    notifyListeners();
  }

  /// Puts the bare token [marker] on the move at [at], or takes it away. A
  /// marker says something about the move rather than to the reader — a quiz
  /// starts here — so the words on it are left alone; everything else is a
  /// comment edit, with the same games written and the same refusals.
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
  /// back, on the chapter it was on. A refused undo leaves the document and
  /// the history alone and says so.
  Future<UndoResult> undo() async {
    final ref = _source;
    if (ref == null) return const UndoRefused();
    final ticket = _opens;
    final result = await _saver.undo();
    if (_disposed || ticket != _opens) return const UndoRefused();
    if (result case Restored(:final text)) {
      final showing = showingGameText(_chapter);
      final read = await readChapter(
        name: p.basenameWithoutExtension(ref.path),
        text: text,
        game: game,
      );
      if (_disposed || ticket != _opens) return const UndoRefused();
      final view = game == null ? _viewOf(read, ref) : null;
      _view = view;
      final restored = view?.chapter ?? showingGame(read, showing);
      final before = _chapter?.tree;
      _chapter = restored;
      _cursor.value = before == null
          ? const NodePath.root()
          : samePathIn(before, restored.tree, cursor);
      notifyListeners();
    }
    return result;
  }

  /// Writes the draft beside the original as `<name>.pgn`, replacing
  /// nothing. A copy changes nothing here, so nothing goes stale: whatever
  /// the user opened meanwhile, the answer is about the file they asked for.
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
    final opened = await open(ChapterRef.at(path), game: game);
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
    _flipped = false;
    _shownTo = null;
    _readOnly = readOnly;
    _refused = readOnly == null ? null : NotEditable(readOnly);
    _saver.opened(ref, revision, readOnly: readOnly);
    _cursor.value = const NodePath.root();
    notifyListeners();
  }

  /// Shows [edited] and puts it on disk, saying which games the edit wrote.
  /// The scope is what the edit reported, never what the text turned out to
  /// look like: that would agree with the text, and the store would have
  /// nothing to refuse.
  ///
  /// A game the edit rewrote keeps the id it is trained under ([withIdsPinned]);
  /// that header lands on a game the edit wrote anyway, so the scope stands.
  void _replace(Chapter edited, GamesWritten written) {
    final view = _view;
    if (view != null) {
      _putBack(
        view,
        edited,
        GamesArranged.of(written, before: view.chapter.lines.length),
      );
      return;
    }
    final before = _chapter;
    final pinned = before == null
        ? edited
        : withIdsPinned(
            before,
            edited,
            GamesArranged.of(written, before: before.lines.length),
          ).chapter;
    _chapter = pinned;
    _saver.save(writeChapter(pinned), GamesEdited(written));
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
      case edits.ChapterEdited(chapter: final edited, :final games)
          when _view != null:
        final reason = _putBack(_view!, edited, games);
        if (reason != null) {
          notifyListeners();
          return reason;
        }
        _clearRefusal();
        _cursor.value = samePathIn(chapter.tree, _chapter!.tree, cursor);
      case edits.ChapterEdited(chapter: final edited, :final games):
        _clearRefusal();
        final pinned = withIdsPinned(chapter, edited, games);
        _chapter = pinned.chapter;
        _saver.save(
          writeChapter(pinned.chapter),
          GamesRearranged(pinned.games),
        );
        _cursor.value = samePathIn(chapter.tree, pinned.chapter.tree, cursor);
    }
    notifyListeners();
    return null;
  }

  /// Where the games at [games] of the open chapter sit in its file: the
  /// same indexes when the chapter is the whole file.
  Set<int> placesInFile(Set<int> games) {
    final view = _view;
    if (view == null) return games;
    return {
      for (final game in games)
        if (game >= 0 && game < view.places.length) view.places[game],
    };
  }

  /// Makes [edit] to the whole file the open chapter is in — the chapters
  /// of a course file named, renamed, taken out — and writes it through the
  /// same one path every edit takes. [section] is the chapter to show after
  /// it, when the edit renamed the one that is open. Answers why it did not
  /// happen, or null when it did.
  String? applyToFile(
    edits.ChapterEdit Function(Chapter file) edit, {
    String? section,
  }) {
    final view = _view;
    final source = _source;
    if (view == null || source == null) return apply(edit);
    if (_refuseWhenReadOnly()) return _readOnly;
    switch (edit(view.file)) {
      case edits.ChapterUnchanged():
        return null;
      case edits.ChapterEditRefused(:final reason):
        log.w('edit ${source.path}', reason);
        _refused = EditNotWritten(reason);
        notifyListeners();
        return reason;
      case edits.ChapterEdited(chapter: final edited, :final games):
        _clearRefusal();
        final pinned = withIdsPinned(view.file, edited, games);
        _saver.save(
          writeChapter(pinned.chapter),
          GamesRearranged(pinned.games),
        );
        final ref = _stillIn(
          pinned.chapter,
          section == null || section == source.section
              ? source
              : ChapterRef.at(source.path, section: section),
        );
        final before = _chapter?.tree;
        final next = sectionView(pinned.chapter, ref.section, name: ref.name);
        _view = next;
        _chapter = next.chapter;
        if (ref != source) {
          _source = ref;
          _saver.relocated(ref);
        }
        _cursor.value = before == null
            ? const NodePath.root()
            : samePathIn(before, next.chapter.tree, cursor);
    }
    notifyListeners();
    return null;
  }

  /// The chapter [ref] names in [file]: null when it is the whole file,
  /// which is every file whose games name no chapter.
  SectionView? _viewOf(Chapter file, ChapterRef ref) {
    final view = sectionView(file, ref.section, name: ref.name);
    return view.isWholeFile ? null : view;
  }

  /// Puts [edited], an edit of [view]'s chapter placed by [games], back into
  /// the file and writes the file, saying in the file's own places what the
  /// edit did. The chapter shown is then the file's again, with the ids the
  /// file trains its games under. Answers why it did not happen, or null.
  String? _putBack(SectionView view, Chapter edited, GamesArranged games) {
    final back = spliced(view, edited, games);
    if (back == null) {
      const reason = 'a new line could not be given its chapter name';
      log.w('edit ${_source?.path}', reason);
      _refused = const EditNotWritten(reason);
      return reason;
    }
    final pinned = withIdsPinned(view.file, back.file, back.games);
    _saver.save(writeChapter(pinned.chapter), GamesRearranged(pinned.games));
    final source = _source!;
    final ref = _stillIn(pinned.chapter, source);
    final next = sectionView(pinned.chapter, ref.section, name: ref.name);
    _view = next;
    _chapter = next.chapter;
    if (ref != source) {
      _source = ref;
      _saver.relocated(ref);
    }
    return null;
  }

  /// [ref], or — when an edit took the last of its games out of [file], or
  /// left the file one chapter — the file's first chapter, so the board
  /// does not show a chapter that is no longer anywhere and names it as the
  /// library does. The draft and its saver stay with the file.
  ChapterRef _stillIn(Chapter file, ChapterRef ref) {
    final sections = chapterSections(file.lines);
    if (sections.contains(ref.section)) return ref;
    return ChapterRef.at(ref.path, section: sections.first);
  }

  @override
  void dispose() {
    _disposed = true;
    _cursor.dispose();
    super.dispose();
  }
}

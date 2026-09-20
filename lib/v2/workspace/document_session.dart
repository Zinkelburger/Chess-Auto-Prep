import 'dart:math' as math;

import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../chess/fen.dart';
import '../chess/pgn/chapter.dart';
import '../chess/pgn/chapter_edits.dart' as edits;
import '../chess/pgn/game_tree.dart';
import '../diagnostics/log.dart';
import '../storage/chapter_files.dart';
import '../storage/document_ref.dart';
import '../storage/edit_scope.dart';
import '../storage/pgn_document_store.dart' as store;
import 'document_saver.dart';
import 'save_state.dart';

sealed class OpenResult {
  const OpenResult();
}

final class DocumentOpened extends OpenResult {
  const DocumentOpened();
}

final class OpenFailed extends OpenResult {
  const OpenFailed(this.reason);

  /// A sentence for the screen.
  final String reason;
}

/// A later open took over. This one changed nothing and has nothing to say.
final class OpenOvertaken extends OpenResult {
  const OpenOvertaken();
}

sealed class CopyResult {
  const CopyResult();
}

final class CopySaved extends CopyResult {
  const CopySaved(this.name);

  /// The file name the copy was written under.
  final String name;
}

/// The name is taken. Nothing was written and nothing was replaced.
final class CopyNameTaken extends CopyResult {
  const CopyNameTaken();
}

final class CopyFailed extends CopyResult {
  const CopyFailed(this.detail);

  final String detail;
}

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
  NodePath _cursor = const NodePath.root();
  edits.GameNotWhole? _refused;
  int _opens = 0;
  bool _disposed = false;

  Chapter? get chapter => _chapter;

  /// Why the last edit did not happen, or null when it did.
  ///
  /// A game reading could not finish keeps its own bytes and is never
  /// generated again, so an edit that would have to write it is refused. The
  /// next edit, and opening another document, clears this.
  edits.GameNotWhole? get refusedEdit => _refused;

  /// The file the chapter was read from.
  ChapterRef? get source => _source;

  GameTree? get tree => _chapter?.tree;

  NodePath get cursor => _cursor;

  Fen get fen => tree?.fenAt(_cursor) ?? Fen.initial;

  Side get orientation => _chapter?.side ?? Side.white;

  /// The move the cursor is on; null at the root.
  MoveNode? get currentMove => tree?.nodeAt(_cursor);

  /// The comment on the move at [at], or the chapter's introduction at the
  /// root; machine tokens included.
  String? commentAt(NodePath at) =>
      at.isRoot ? tree?.rootComment : tree?.nodeAt(at)?.comment;

  /// The comment the file wrote before the move at [at], which is how a
  /// variation is introduced. Nothing edits it; it is shown so that a note
  /// the file holds is not invisible.
  String? startingCommentAt(NodePath at) => tree?.nodeAt(at)?.startingComment;

  /// Reads [ref] through the store, so the session holds the revision every
  /// later save is checked against.
  Future<OpenResult> open(ChapterRef ref) async {
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
      case store.Opened(:final text, :final revision):
        _show(parseChapter(name: ref.name, text: text), ref, revision);
        return const DocumentOpened();
      case store.Absent():
        return _openFailed(ref, '${ref.name} is no longer on disk');
      case store.Unreadable(:final detail):
        return _openFailed(ref, 'Could not read ${ref.name}: $detail');
    }
  }

  /// Throws the draft away and takes what is on disk, which is how a
  /// conflict ends when the user decides the other version wins.
  Future<OpenResult> reloadFromDisk() async {
    final ref = _source;
    if (ref == null) return const OpenOvertaken();
    return open(ref);
  }

  /// The open document was renamed or moved. It is the same file with the
  /// same bytes, so only the name the workspace shows and the file later
  /// saves go to change.
  void relocated(ChapterRef ref) {
    final chapter = _chapter;
    if (_source == null || chapter == null) return;
    _source = ref;
    _chapter = renamedChapter(chapter, ref.name);
    _saver.relocated(ref);
    notifyListeners();
  }

  /// The open document was deleted. The workspace empties rather than showing
  /// a chapter whose file is now in the recovery folder.
  void closed() {
    if (_source == null) return;
    _opens++;
    _chapter = null;
    _source = null;
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
  /// An illegal move is ignored: the board offers legal moves only, so this
  /// can only be a request nobody made.
  void playMove(String uci) {
    final chapter = _chapter;
    if (chapter == null) return;
    switch (edits.addMove(chapter, at: _cursor, uci: uci)) {
      case edits.MoveIllegal():
        return;
      case edits.MoveAdded(chapter: final edited, :final path):
        _refused = null;
        _cursor = path;
        if (!identical(edited, chapter)) _replace(chapter, edited);
        notifyListeners();
    }
  }

  /// Writes [text] as the comment on the move at [at], or as the chapter's
  /// introduction when [at] is the root. The path is the caller's, not the
  /// cursor's, so words typed under one move cannot land on another when the
  /// cursor moves first. Text that would leave the file as it is changes
  /// nothing.
  ///
  /// A game reading could not finish cannot take the comment, and then
  /// nothing is written and [refusedEdit] says so.
  void setComment(NodePath at, String? text) {
    final chapter = _chapter;
    if (chapter == null) return;
    final hadRefusal = _refused != null;
    switch (edits.setComment(chapter, at: at, text: text)) {
      case edits.GameNotWhole():
        log.w(
          'comment ${_source?.path}',
          'the game holding that move was not read whole',
        );
        _refused = const edits.GameNotWhole();
      case edits.CommentWritten(chapter: final edited):
        _refused = null;
        if (identical(edited, chapter)) {
          if (!hadRefusal) return;
        } else {
          _replace(chapter, edited);
        }
    }
    notifyListeners();
  }

  /// Puts the file back as it was before the last edit and shows what came
  /// back. A refused undo leaves the document and the history alone, and
  /// says so: nothing happening is something the screen has to tell.
  Future<UndoResult> undo() async {
    final ref = _source;
    if (ref == null) return const UndoRefused();
    final ticket = _opens;
    final result = await _saver.undo();
    if (_disposed || ticket != _opens) return const UndoRefused();
    if (result case Restored(:final text)) {
      final before = _chapter?.tree;
      final restored = parseChapter(name: ref.name, text: text);
      _chapter = restored;
      _cursor = before == null
          ? const NodePath.root()
          : _sameMoves(before, restored.tree, _cursor);
      notifyListeners();
    }
    return result;
  }

  /// Writes the draft beside the original as `<name>.pgn`, replacing
  /// nothing. The session stays on the document it had open.
  ///
  /// A copy changes nothing here, so nothing about it goes stale: whatever
  /// the user opened while it was being written, the answer is about the
  /// file they asked for and they are told it.
  Future<CopyResult> saveCopy(String name) async {
    final ref = _source;
    final chapter = _chapter;
    if (ref == null || chapter == null) {
      return const CopyFailed('there is nothing open to copy');
    }
    final file = p.extension(name) == '.pgn' ? name : '$name.pgn';
    final target = DocumentRef(p.join(p.dirname(ref.path), file));
    final created = await _store.create(target, writeChapter(chapter));
    return switch (created) {
      store.Created() => CopySaved(file),
      store.Collision() => const CopyNameTaken(),
      store.IoFailure(:final detail) => CopyFailed(detail),
    };
  }

  void _show(Chapter chapter, ChapterRef ref, Revision revision) {
    _chapter = chapter;
    _source = ref;
    _cursor = const NodePath.root();
    _refused = null;
    _saver.opened(ref, revision);
    notifyListeners();
  }

  void _replace(Chapter before, Chapter edited) {
    _chapter = edited;
    _saver.save(writeChapter(edited), _gamesRewritten(before, edited));
  }

  OpenFailed _openFailed(ChapterRef ref, String reason) {
    log.w('open ${ref.path}', reason);
    return OpenFailed(reason);
  }

  /// Where the moves [path] names in [before] are in [after].
  ///
  /// The moves are followed by name, not by their places in the lists: a
  /// path is only a route through a particular tree, and the same numbers in
  /// a file the user just took back can name entirely different moves. A move
  /// the restored file does not have leaves the cursor on the deepest move
  /// above it that it does.
  NodePath _sameMoves(GameTree before, GameTree after, NodePath path) {
    final kept = <int>[];
    var siblings = after.children;
    for (final step in before.lineTo(path)) {
      final index = siblings.indexWhere((node) => node.san == step.san);
      if (index < 0) break;
      kept.add(index);
      siblings = siblings[index].children;
    }
    return NodePath.of(kept);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// The games [edited] writes again where [before] kept the bytes the file
/// had.
///
/// A chapter's persistent unit is the game: an edit writes the games it
/// changed and every other one keeps its own text, so the two chapters
/// compared say exactly which games the file is about to change. The store
/// is told that and refuses the write if the text does anything else — a
/// game gone, a game rewritten that nobody edited.
EditScope _gamesRewritten(Chapter before, Chapter edited) {
  final games = <int>{};
  final shared = math.min(before.lines.length, edited.lines.length);
  for (var index = 0; index < shared; index++) {
    if (edited.lines[index].text != before.lines[index].text) games.add(index);
  }
  // Never negative: no edit here removes a game, and a chapter that lost one
  // is the mistake the store is meant to catch rather than a scope to claim.
  final added = edited.lines.length - before.lines.length;
  return GamesEdited(games, appended: added > 0 ? added : 0);
}

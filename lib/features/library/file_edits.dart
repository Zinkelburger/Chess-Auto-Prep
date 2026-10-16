import '../../chess/pgn/chapter.dart';
import '../../chess/pgn/chapter_edit.dart';
import '../../chess/pgn/chapter_sections.dart';
import '../../chess/pgn/line_id_pins.dart';
import '../../chess/pgn/line_moves.dart';
import '../../storage/chapter_files.dart';
import '../../storage/edit_scope.dart';
import '../../storage/pgn_document_store.dart' as store;
import '../../storage/reference_change.dart';
import '../../workspace/document_saver.dart';
import '../../workspace/document_session.dart';
import 'file_changes.dart';
import 'library_state.dart';
import 'line_transfers.dart';

/// How an edit to what a chapter file holds lands: lines moved between
/// chapters, and a course file's chapters renamed or taken out.
///
/// The file open in the workspace is edited through it, so the edit lands
/// behind its draft and its undo covers it; any other is read, edited and
/// saved against the revision read. A move of lines into another file is
/// [LineTransfers]' to make.
final class FileEdits {
  FileEdits({
    required this._store,
    required this._saver,
    required this._session,
    required this._changes,
    required this._lineTransfers,
  });

  final store.PgnDocumentStore _store;
  final DocumentSaver _saver;
  final DocumentSession _session;
  final FileChanges _changes;
  final LineTransfers _lineTransfers;

  /// Moves the lines at [games] of the open chapter into [to]: as lines of
  /// their own, or folded into the line at [asSidelineOf] there as
  /// variations.
  ///
  /// Cross-file moves publish both PGNs and their training keys in one
  /// recoverable transaction. Retry and undo retain that same read set.
  ///
  /// [chapter] and [from] are what was open when the user asked: the
  /// indexes in [games] belong to them.
  Future<LibraryResult> moveLines(
    Chapter chapter,
    ChapterRef from, {
    required Set<int> games,
    required ChapterRef to,
    int? asSidelineOf,
  }) async {
    final moving = games.where((g) => g != asSidelineOf || to != from).toSet();
    final lines = [
      for (final game in moving.toList()..sort())
        if (game >= 0 && game < chapter.lines.length) chapter.lines[game],
    ];
    if (lines.isEmpty) return const LibraryDone();
    if (to == from) {
      // Every line is checked before any is grafted: a refusal part way
      // through would leave the lines already grafted in two places.
      if (asSidelineOf != null && lines.any((line) => !line.isWhole)) {
        return const LibraryFailure(lineNotWholeReason);
      }
      return _foldedHere(moving, asSidelineOf);
    }
    if (to.path == from.path) {
      // Another chapter of the same file: the lines keep their places and
      // take the other chapter's name, one edit to one file.
      if (asSidelineOf != null) {
        return const LibraryFailure(
          'a line can only be folded into a line of the chapter on the board',
        );
      }
      final places = _session.placesInFile(moving);
      final reason = _session.applyToFile(
        (file) => linesNamed(file, places, to.section),
      );
      if (reason != null) return LibraryFailure(reason);
      return _saved();
    }
    return _lineTransfers.move(chapter, from, moving, to, asSidelineOf);
  }

  /// One line folded into another of the open chapter, then taken out.
  LibraryResult _foldedHere(Set<int> games, int? host) {
    if (host == null) return const LibraryDone();
    for (final game in games) {
      final reason = _session.apply(
        (c) => lineGraftedInto(c, host: host, line: c.lines[game]),
      );
      if (reason != null) return LibraryFailure(reason);
    }
    final reason = _session.apply((c) => linesTakenOut(c, games: games));
    return reason == null ? const LibraryDone() : LibraryFailure(reason);
  }

  /// Makes [edit] to the whole file [ref] is in: through the workspace when
  /// that file is open, so the edit lands behind its draft and its undo
  /// covers it; otherwise read, edited and saved against the revision read.
  /// [renamedTo] is what [ref] is called afterwards, when the edit renamed
  /// it, and [references] the book entries that follow the new name.
  Future<LibraryResult> editFile(
    ChapterRef ref,
    ChapterEdit Function(Chapter file) edit, {
    String? renamedTo,
    ReferenceChanges? references,
  }) async {
    // By path: any chapter of the open file is the open file.
    if (_session.source?.path == ref.path) {
      return _editedOpen(ref, edit, renamedTo, references);
    }
    final read = await _store.open(ref);
    if (read is! store.Opened) {
      return LibraryFailure('${ref.name} could not be read');
    }
    final file = await readChapter(name: ref.fileName, text: read.text);
    // The user may have opened the file while it was being read. Saved from
    // here, the edit would change it under the revision the workspace just
    // took, and the workspace's next save would be refused.
    if (_session.source?.path == ref.path) {
      return _editedOpen(ref, edit, renamedTo, references);
    }
    switch (edit(file)) {
      case ChapterUnchanged():
        return const LibraryDone();
      case ChapterEditRefused(:final reason):
        return LibraryFailure(reason);
      case ChapterEdited(chapter: final edited, :final games):
        final pinned = withIdsPinned(file, edited, games);
        final scope = GamesRearranged(pinned.games, references: references);
        final text = writeChapter(pinned.chapter);
        Future<store.SaveResult> save() =>
            _store.save(ref, text, expected: read.revision, scope: scope);
        return _savedResult(await _changes.save(ref, references, save));
    }
  }

  LibraryResult _savedResult(store.SaveResult result) => switch (result) {
    store.Saved() => const LibraryDone(),
    store.Conflict() => const LibraryStale(),
    store.SaveDidNotLand(:final detail) => LibraryFailure(detail),
  };

  /// [edit] made through the workspace, which has [ref]'s file open. The
  /// chapter on the board follows a rename only when it is the chapter
  /// renamed: renaming another chapter of the file leaves it where it is.
  Future<LibraryResult> _editedOpen(
    ChapterRef ref,
    ChapterEdit Function(Chapter file) edit,
    String? renamedTo,
    ReferenceChanges? references,
  ) async {
    final reason = _session.applyToFile(
      edit,
      section: _session.source == ref ? renamedTo : null,
      references: references,
    );
    if (reason != null) return LibraryFailure(reason);
    return _saved();
  }

  /// Waits for an edit made through the workspace to reach its file. The
  /// list is read again after every change, and an edit still on the
  /// saver's clock would leave it naming what the file held a moment ago:
  /// a renamed chapter under its old name, one taken out still there.
  /// Held edits wait for the user to keep them, which the draft already
  /// says; the change is made all the same.
  Future<LibraryResult> _saved() async {
    await _saver.flush();
    if (_session.hasHeldEdits || _saver.settled) return const LibraryDone();
    return switch (_saver.state) {
      SaveConflict() => const LibraryConflicted(),
      SaveFailed(:final detail) => LibraryFailure(detail),
      _ => const LibraryFailure('the change is on the board, not in the file'),
    };
  }
}

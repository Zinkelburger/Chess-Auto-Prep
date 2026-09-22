import '../../chess/pgn/chapter.dart';
import '../../chess/pgn/chapter_edit.dart';
import '../../chess/tactics/analyzed_games.dart';
import '../../chess/tactics/mined_set.dart';
import '../../chess/tactics/mining.dart';
import '../../diagnostics/log.dart';
import '../../storage/edit_scope.dart';
import '../../storage/pgn_document_store.dart';
import '../../workspace/document_saver.dart';
import '../../workspace/document_session.dart';
import 'tactics_set.dart';

/// What adding a reviewed game's puzzles came to.
sealed class Addition {
  const Addition();
}

/// The puzzles are on disk and the game is marked done. [added] leaves out
/// puzzles whose position the set already had.
final class Added extends Addition {
  const Added(this.added);

  final int added;
}

/// Nothing was written; [reason] is for the log and the status line.
final class NotAdded extends Addition {
  const NotAdded(this.reason);

  final String reason;
}

/// Adds mined puzzles to the tactics set, and says which games are done.
///
/// The set has one writer at a time. While it is the document in the
/// workspace — a puzzle is up — the session is that writer: the puzzles go
/// in through [DocumentSession.apply] and out through its saver, which the
/// addition waits for, so an attempt the solver is recording and the new
/// puzzles are one queue of saves and neither overwrites the other. While
/// it is not open, this writes it through the store against the revision it
/// read, reading again when the file changed meanwhile.
///
/// One gap remains: the set opened in the workspace between this reading it
/// and the store's write holds a revision a moment old, and its next save is
/// refused as a conflict — the file is never overwritten, and reopening the
/// set shows everything.
final class SetAdditions {
  SetAdditions({
    required PgnDocumentStore documents,
    required DocumentSession session,
    required DocumentSaver saver,
    required TacticsSet set,
    required Future<Set<String>> Function() older,
  }) : _documents = documents,
       _session = session,
       _saver = saver,
       _set = set,
       _older = older;

  final PgnDocumentStore _documents;
  final DocumentSession _session;
  final DocumentSaver _saver;
  final TacticsSet _set;

  /// The ids the old app kept apart from the set, still counted as done.
  final Future<Set<String>> Function() _older;

  /// How many times a write that lost a race with another writer is tried.
  static const _attempts = 3;

  /// The games already reviewed, by either app; null when the set cannot be
  /// read, which is no answer: mining then would mine everything again.
  Future<Set<String>?> analyzed() async {
    final older = await _older();
    if (_set.isOpen) {
      final open = _session.chapter;
      return open == null ? null : _idsIn(open.preamble, older);
    }
    return switch (await _documents.open(_set.ref)) {
      Absent() => older,
      Opened(:final text) => _idsIn(
        (await readChapter(name: _set.ref.name, text: text)).preamble,
        older,
      ),
      Unreadable(:final detail) => _unreadable(detail),
    };
  }

  /// Adds [puzzles], from the game [gameId], and marks the game done, in
  /// one write.
  Future<Addition> add(String gameId, List<MinedPuzzle> puzzles) async {
    final older = await _older();
    if (_set.isOpen) return _addInSession(gameId, puzzles, older);
    for (var attempt = 1; attempt <= _attempts; attempt++) {
      final written = await _addOnDisk(gameId, puzzles, older);
      if (written != null) {
        if (written is Added) await _set.load();
        return written;
      }
    }
    return const NotAdded('the set kept changing while it was written');
  }

  Future<Addition> _addInSession(
    String gameId,
    List<MinedPuzzle> puzzles,
    Set<String> older,
  ) async {
    var added = 0;
    final refused = _session.apply((set) {
      final edit = _edit(set, gameId, puzzles, older);
      if (edit is ChapterEdited) {
        added = edit.chapter.lines.length - set.lines.length;
      }
      return edit;
    });
    if (refused != null) return NotAdded(refused);
    await _saver.flush();
    return _saver.settled
        ? Added(added)
        : const NotAdded('the set could not be saved');
  }

  /// One attempt; null when the file changed between the read and the write.
  Future<Addition?> _addOnDisk(
    String gameId,
    List<MinedPuzzle> puzzles,
    Set<String> older,
  ) async {
    final ref = _set.ref;
    switch (await _documents.open(ref)) {
      case Absent():
        final set = parseChapter(name: ref.name, text: '');
        final edit = _edit(set, gameId, puzzles, older);
        if (edit is! ChapterEdited) return _notEdited(edit);
        final text = writeChapter(edit.chapter);
        return switch (await _documents.create(ref, text)) {
          Created() => Added(edit.chapter.lines.length),
          Collision() => null,
          IoFailure(:final detail) => NotAdded(detail),
        };
      case Opened(:final readOnly?):
        return NotAdded(readOnly);
      case Opened(:final text, :final revision):
        final set = await readChapter(name: ref.name, text: text);
        final edit = _edit(set, gameId, puzzles, older);
        if (edit is! ChapterEdited) return _notEdited(edit);
        return switch (await _documents.save(
          ref,
          writeChapter(edit.chapter),
          expected: revision,
          scope: GamesRearranged(edit.games),
        )) {
          Saved() => Added(edit.chapter.lines.length - set.lines.length),
          Conflict() => null,
          SaveDidNotLand(:final detail) => NotAdded(detail),
        };
      case Unreadable(:final detail):
        return NotAdded(detail);
    }
  }

  static ChapterEdit _edit(
    Chapter set,
    String gameId,
    List<MinedPuzzle> puzzles,
    Set<String> older,
  ) {
    final Set<String> done;
    try {
      done = {
        ...analyzedIn(set.preamble),
        ...older,
        if (gameId.isNotEmpty) gameId,
      };
    } on FormatException catch (error) {
      return ChapterEditRefused('its analysed-games line: ${error.message}');
    }
    return withMined(set, puzzles, analyzed: done);
  }

  static Addition _notEdited(ChapterEdit edit) => switch (edit) {
    ChapterEditRefused(:final reason) => NotAdded(reason),
    _ => const Added(0),
  };

  static Set<String>? _idsIn(String preamble, Set<String> older) {
    try {
      return {...analyzedIn(preamble), ...older};
    } on FormatException catch (error) {
      return _unreadable(error.message);
    }
  }

  static Set<String>? _unreadable(String detail) {
    log.w('read the analysed games of the tactics set', detail);
    return null;
  }
}

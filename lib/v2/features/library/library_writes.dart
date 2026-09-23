import 'dart:isolate';

import 'package:dartchess/dartchess.dart' show Side;
import 'package:path/path.dart' as p;

import '../../chess/pgn/chapter.dart';
import '../../chess/pgn/chapter_edit.dart';
import '../../chess/pgn/chapter_line.dart';
import '../../chess/pgn/chapter_sections.dart';
import '../../chess/pgn/line_id_pins.dart';
import '../../chess/pgn/games_written.dart';
import '../../chess/pgn/line_moves.dart';
import '../../chess/pgn/repertoire_import.dart';
import '../../diagnostics/log.dart';
import '../../storage/chapter_files.dart';
import '../../storage/document_ref.dart';
import '../../storage/edit_scope.dart';
import '../../storage/pgn_document_store.dart' as store;
import '../../storage/training_records.dart' as records;
import '../../ui/file_names.dart';
import '../../workspace/document_saver.dart';
import '../../workspace/document_session.dart';
import 'library_state.dart';

/// How one change to the repertoire files lands on disk, and how the
/// workspace follows it.
///
/// Every write goes through the document store, because that is what carries
/// the training records with it: a chapter's reviews, progress and history
/// are keyed by its path, and the store repoints them inside the same
/// operation. A chapter changes one file at a time; a repertoire renames as
/// one folder, so it cannot end up split in two, and deletes chapter by
/// chapter, because each one is quarantined separately.
///
/// The chapter open in the workspace is written only while its saver holds
/// it still, and the session is told where it went. Holds no state of its
/// own: which change may run, and the list it changes, are the [Library]'s.
final class LibraryWrites {
  LibraryWrites({
    required ChapterFiles files,
    required store.PgnDocumentStore documents,
    required DocumentSession session,
    required DocumentSaver saver,
    required String root,
  }) : _files = files,
       _store = documents,
       _session = session,
       _saver = saver,
       _root = root;

  final ChapterFiles _files;
  final store.PgnDocumentStore _store;
  final DocumentSession _session;
  final DocumentSaver _saver;

  /// The `repertoires` folder, absolute: where imports are staged.
  final String _root;

  /// A new chapter file at [ref] with no lines, starting at [rootMoves].
  Future<LibraryResult> create(
    DocumentRef ref,
    String name,
    Side? side, {
    List<String> rootMoves = const [],
  }) async {
    final text = newChapterText(
      name: name,
      side: side,
      created: DateTime.now(),
      rootMoves: rootMoves,
    );
    return switch (await _store.create(ref, text)) {
      store.Created() => const LibraryDone(),
      store.Collision() => const LibraryNameTaken(),
      store.IoFailure(:final detail) => LibraryFailure(detail),
    };
  }

  /// The side [folder] trains, from the first chapter that can be read.
  /// A folder nobody can read is White, which is what an unmarked chapter is.
  Future<Side> sideOf(RepertoireFolder folder) async {
    for (final chapter in folder.chapters) {
      if (await _store.open(chapter) case store.Opened(:final text)) {
        return chapterSide(text);
      }
    }
    return Side.white;
  }

  /// What the file at [path] holds, imported as [importText] imports.
  Future<LibraryResult> importFile(
    String path, {
    required String folder,
  }) async {
    switch (await _store.open(DocumentRef(path))) {
      case store.Opened(:final text):
        return importText(text, folder: folder);
      case store.Absent():
        return const LibraryFileUnreadable('the file is not there');
      case store.Unreadable(:final detail):
        return LibraryFileUnreadable(detail);
    }
  }

  /// [text] as the repertoire [folder]: its variations become lines and its
  /// chapters, when it has any, become chapter files.
  ///
  /// The files are written into a staging folder the list does not show and
  /// the folder is then renamed into place, so a write that stops half way
  /// never leaves a repertoire with some of its chapters in the list.
  Future<LibraryResult> importText(
    String text, {
    required String folder,
  }) async {
    // A course of a thousand games is read where the screen does not wait
    // for it; a pasted line is not worth the trip.
    final created = DateTime.now();
    final read = text.length < readOffThreadFrom
        ? readImport(text, created: created)
        : await Isolate.run(() => readImport(text, created: created));
    if (read is! ImportedChapters) return const LibraryNothingToImport();
    final staging = p.join(_root, '$stagingPrefix${_stagingId()}');
    final names = chapterFileNames(read.chapters);
    for (final (index, chapter) in read.chapters.indexed) {
      final ref = DocumentRef(p.join(staging, '${names[index]}.pgn'));
      final refused = switch (await _store.create(ref, chapter.text)) {
        store.Created() => null,
        store.Collision() => LibraryFailure('${ref.path} was already there'),
        store.IoFailure(:final detail) => LibraryFailure(detail),
      };
      if (refused == null) continue;
      await _files.removeStaging(staging);
      return refused;
    }
    final destination = p.join(_root, folder);
    switch (await _store.moveFolder(staging, destination)) {
      case store.FolderMoved():
        return LibraryAdded(
          ChapterRef.at(p.join(destination, '${names.first}.pgn')),
          chapters: read.chapters.length,
          lines: read.lines,
        );
      case store.FolderNameTaken():
        await _files.removeStaging(staging);
        return const LibraryNameTaken();
      case store.FolderMoveFailed(:final detail):
        await _files.removeStaging(staging);
        return LibraryFailure(detail);
    }
  }

  String _stagingId() =>
      DateTime.now().microsecondsSinceEpoch.toRadixString(36);

  /// The chapter at [ref] renamed or moved to [to]. The workspace follows it
  /// when it has it open.
  Future<LibraryResult> relocate(ChapterRef ref, DocumentRef to) =>
      _withRevision(ref, (revision) async {
        switch (await _store.move(ref, to, expected: revision)) {
          case store.Moved(:final training):
            if (_session.source?.path == ref.path) {
              _session.relocated(ChapterRef.at(to.path));
            }
            return LibraryDone(training: training);
          case store.Collision():
            return const LibraryNameTaken();
          case store.Conflict():
            return const LibraryStale();
          case store.IoFailure(:final detail):
            return LibraryFailure(detail);
        }
      });

  /// The chapter at [ref] to the recovery folder. The workspace closes it
  /// when it has it open.
  Future<LibraryResult> remove(ChapterRef ref) =>
      _withRevision(ref, (revision) async {
        switch (await _store.delete(ref, expected: revision)) {
          case store.Deleted(:final training):
            if (_session.source?.path == ref.path) _session.closed();
            return LibraryDone(training: training);
          case store.Conflict():
            return const LibraryStale();
          case store.IoFailure(:final detail):
            return LibraryFailure(detail);
        }
      });

  /// The folder moves whole, in one rename: its chapters, the raw-game
  /// sidecars written beside them and the generation bundles under it. A
  /// chapter-at-a-time rename that stopped half way would split one
  /// repertoire across two folders and strand the rest of its files in the
  /// one that then vanishes from the list.
  Future<LibraryResult> renameFolder(RepertoireFolder folder, String to) async {
    final open = _session.source;
    if (open == null || !p.isWithin(folder.path, open.path)) {
      return _movedFolder(folder.path, to);
    }
    // The chapter in the workspace is inside the folder, so its autosave is
    // held still for the length of the move, as its own rename holds it.
    return await _saver.holdStill((_) => _movedFolder(folder.path, to)) ??
        const LibraryBusy();
  }

  /// Recoverable: each chapter goes to the recovery folder through the store,
  /// so its training rows follow it there and come back with it. A chapter
  /// that refuses stops the delete where it is — the ones already gone are in
  /// recovery — and the folder stays, because the rest is still in it.
  Future<LibraryResult> deleteFolder(RepertoireFolder folder) async {
    final repointed = <records.RepointResult>[];
    for (final chapter in folder.chapters) {
      final result = await remove(chapter);
      if (result case LibraryDone(:final training)) {
        repointed.add(training);
        continue;
      }
      return LibraryStoppedAt(chapter.name, result);
    }
    await _files.removeIfEmpty(folder.path);
    return LibraryDone(training: foldedRepoint(repointed));
  }

  Future<LibraryResult> _movedFolder(String from, String to) async {
    switch (await _store.moveFolder(from, to)) {
      case store.FolderMoved(:final training):
        _followedFolder(from, to);
        return LibraryDone(training: training);
      case store.FolderNameTaken():
        return const LibraryNameTaken();
      case store.FolderMoveFailed(:final detail):
        return LibraryFailure(detail);
    }
  }

  /// The workspace follows a chapter whose whole folder moved under it. The
  /// user may have opened another one while the move was in flight, which is
  /// why the open file is read again rather than remembered.
  void _followedFolder(String from, String to) {
    final open = _session.source;
    if (open == null || !p.isWithin(from, open.path)) return;
    _session.relocated(
      ChapterRef.at(p.join(to, p.relative(open.path, from: from))),
    );
  }

  /// Moves the lines at [games] of the open chapter into [to]: as lines of
  /// their own, or folded into the line at [asSidelineOf] there as
  /// variations.
  ///
  /// Two files, two saves, in the safe order: the lines are written into
  /// [to] first, against the revision it was read at, and only then taken
  /// out of the open chapter. A refusal on the way in changes nothing; a
  /// refusal on the way out leaves the lines in both files and says so,
  /// which is a duplicate the user can see rather than a loss they cannot.
  /// Within one chapter — a line dropped on another line of the same file —
  /// it is one document folded and then trimmed, through the session.
  Future<LibraryResult> moveLines({
    required Set<int> games,
    required ChapterRef to,
    int? asSidelineOf,
  }) async {
    final chapter = _session.chapter;
    final from = _session.source;
    if (chapter == null || from == null) {
      return const LibraryFailure('there is no chapter open to move from');
    }
    final moving = games.where((g) => g != asSidelineOf || to != from).toSet();
    final lines = [
      for (final game in moving.toList()..sort())
        if (game >= 0 && game < chapter.lines.length) chapter.lines[game],
    ];
    if (lines.isEmpty) return const LibraryDone();
    if (to == from) return _foldedHere(moving, asSidelineOf);
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
      return reason == null ? const LibraryDone() : LibraryFailure(reason);
    }
    final written = await _writtenInto(to, lines, asSidelineOf);
    if (written != null) return written;
    final reason = _session.apply((c) => linesTakenOut(c, games: moving));
    if (reason == null) return const LibraryDone();
    return LibraryFailure(
      'the lines were added to ${to.name} but not taken out of '
      '${from.name}: $reason',
    );
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

  /// Puts [lines] into [to] on disk, or answers why it could not.
  Future<LibraryResult?> _writtenInto(
    ChapterRef to,
    List<ChapterLine> lines,
    int? host,
  ) async {
    final read = await _store.open(to);
    if (read is! store.Opened) {
      return LibraryFailure('${to.name} could not be read');
    }
    final file = await readChapter(name: to.fileName, text: read.text);
    final view = sectionView(file, to.section);
    var target = view.chapter;
    var arranged = GamesArranged.of(
      GamesWritten(),
      before: target.lines.length,
    );
    for (final edit in _editsInto(lines, host)) {
      switch (edit(target)) {
        case ChapterUnchanged():
          continue;
        case ChapterEditRefused(:final reason):
          return LibraryFailure(reason);
        case ChapterEdited(:final chapter, :final games):
          target = chapter;
          arranged = composedArrangement(arranged, games) ?? games;
      }
    }
    // A chapter of a course file goes back into its file.
    var text = writeChapter(target);
    if (!view.isWholeFile) {
      final back = spliced(view, target, arranged);
      if (back == null) {
        return const LibraryFailure(
          'the lines could not be given their chapter name',
        );
      }
      text = writeChapter(back.file);
      arranged = back.games;
    }
    return switch (await _store.save(
      to,
      text,
      expected: read.revision,
      scope: GamesRearranged(arranged),
    )) {
      store.Saved() => null,
      store.Conflict() => const LibraryStale(),
      store.SaveDidNotLand(:final detail) => LibraryFailure(detail),
    };
  }

  /// Makes [edit] to the whole file [ref] is in: through the workspace when
  /// that file is open, so the edit lands behind its draft and its undo
  /// covers it; otherwise read, edited and saved against the revision read.
  /// [section] is what the open chapter is called afterwards, when the edit
  /// renamed it.
  Future<LibraryResult> editFile(
    ChapterRef ref,
    ChapterEdit Function(Chapter file) edit, {
    String? section,
  }) async {
    if (_session.source?.path == ref.path) {
      final reason = _session.applyToFile(edit, section: section);
      return reason == null ? const LibraryDone() : LibraryFailure(reason);
    }
    final read = await _store.open(ref);
    if (read is! store.Opened) {
      return LibraryFailure('${ref.name} could not be read');
    }
    final file = await readChapter(name: ref.fileName, text: read.text);
    switch (edit(file)) {
      case ChapterUnchanged():
        return const LibraryDone();
      case ChapterEditRefused(:final reason):
        return LibraryFailure(reason);
      case ChapterEdited(chapter: final edited, :final games):
        final pinned = withIdsPinned(file, edited, games);
        return switch (await _store.save(
          ref,
          writeChapter(pinned.chapter),
          expected: read.revision,
          scope: GamesRearranged(pinned.games),
        )) {
          store.Saved() => const LibraryDone(),
          store.Conflict() => const LibraryStale(),
          store.SaveDidNotLand(:final detail) => LibraryFailure(detail),
        };
    }
  }

  /// The edits that put [lines] into a chapter: one append, or one graft
  /// per line into the game at [host].
  List<ChapterEdit Function(Chapter)> _editsInto(
    List<ChapterLine> lines,
    int? host,
  ) => host == null
      ? [(c) => linesAddedTo(c, lines: lines)]
      : [
          for (final line in lines)
            (c) => lineGraftedInto(c, host: host, line: line),
        ];

  /// Runs [write] against the revision the chapter has now.
  ///
  /// The chapter open in the workspace is held still by its saver for the
  /// length of the operation, so a rename cannot land between an autosave and
  /// its answer. Any other chapter is read from disk, which is also the check
  /// that it is still there — and the whole file, because a revision is a
  /// hash of the bytes and there is nothing cheaper to read.
  Future<LibraryResult> _withRevision(
    ChapterRef ref,
    Future<LibraryResult> Function(Revision revision) write,
  ) async {
    // By path: any chapter of the open file is the open file.
    if (_session.source?.path == ref.path) return _held(write);
    switch (await _store.open(ref)) {
      case store.Opened(:final revision):
        // The user may have opened this very chapter while it was being read,
        // and from here on its writes belong behind the saver's hold.
        if (_session.source?.path == ref.path) return _held(write);
        return write(revision);
      case store.Absent():
        return const LibraryStale();
      case store.Unreadable(:final detail):
        log.w('read ${ref.path} before changing it', detail);
        return LibraryFailure(detail);
    }
  }

  /// Runs [write] with the open chapter held still by its saver.
  ///
  /// The revision it writes against is the saver's, so a refusal means the
  /// file changed under the workspace. Trying again cannot help while the
  /// workspace still holds the old revision, which is why that is a result of
  /// its own rather than the retryable [LibraryStale].
  Future<LibraryResult> _held(
    Future<LibraryResult> Function(Revision revision) write,
  ) async {
    final result = await _saver.holdStill(write);
    if (result == null) return const LibraryBusy();
    return result is LibraryStale ? const LibraryConflicted() : result;
  }
}

/// A file name for each chapter, from its title, no two alike.
List<String> chapterFileNames(List<ImportedChapter> chapters) {
  final taken = <String>{};
  final names = <String>[];
  for (final (index, chapter) in chapters.indexed) {
    final base = importedName(chapter.title, fallback: 'Chapter ${index + 1}');
    var candidate = base;
    for (var n = 2; !taken.add(candidate.toLowerCase()); n++) {
      candidate = '$base ($n)';
    }
    names.add(candidate);
  }
  return names;
}

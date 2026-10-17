import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../../chess/pgn/chapter.dart';
import '../../chess/pgn/chapter_sections.dart';
import '../../chess/pgn/repertoire_import.dart';
import '../../storage/chapter_files.dart';
import '../../storage/document_ref.dart';
import '../../storage/pgn_document_store.dart' as store;
import '../../ui/file_names.dart';
import 'library_state.dart';

/// How a PGN becomes a new repertoire: its variations become lines and a
/// course's chapters become chapters of one file, written into a staging
/// folder and renamed into place under the first name no repertoire has.
final class LibraryImports {
  LibraryImports({
    required this._store,
    required this._files,
    required this._root,
    required this._now,
    required this._named,
  });

  final store.PgnDocumentStore _store;
  final ChapterFiles _files;

  /// The `repertoires` folder, absolute.
  final String _root;

  /// What an imported chapter's heading says it was created on.
  final DateTime Function() _now;

  /// The repertoire in the list called [name], compared without case as the
  /// library compares names; null when the list has none.
  final RepertoireFolder? Function(String name) _named;

  /// How many names an import tries before it says the name is taken.
  static const _namesTried = 100;

  /// [name], then `name (2)`, `name (3)`…, leaving out every name a
  /// repertoire in the list has, compared without case as [_named] compares.
  ///
  /// The disk can still have one of them: a repertoire whose chapters were
  /// all deleted keeps its folder, because their recovery copies are in it,
  /// and the list does not show a folder with no chapter in it. The move into
  /// place is what finds that out, so an import tries these in turn.
  List<String> _freeNames(String name) {
    final names = <String>[];
    for (var n = 1; names.length < _namesTried; n++) {
      final candidate = n == 1 ? name : '$name ($n)';
      if (_named(candidate) == null) names.add(candidate);
    }
    return names;
  }

  /// What the file at [path] holds, imported as [importText] imports.
  Future<LibraryResult> importFile(String path, {required String name}) async {
    switch (await _store.open(DocumentRef(path))) {
      case store.Opened(:final text):
        return importText(text, name: name);
      case store.Absent():
        return const LibraryFileUnreadable('the file is not there');
      case store.Unreadable(:final detail):
        return LibraryFileUnreadable(detail);
    }
  }

  /// [text] as the repertoire [name], or the first of [_freeNames] a folder
  /// can take: its variations become lines, and a course's chapters become
  /// chapters of one file, each line naming its chapter in `[ChapterName]`
  /// ([courseText]).
  ///
  /// The file is written into a staging folder the list does not show and
  /// the folder is then renamed into place, so a write that stops half way
  /// never leaves a repertoire half there.
  Future<LibraryResult> importText(String text, {required String name}) async {
    // A course of a thousand games is read where the screen does not wait
    // for it; a pasted line is not worth the trip.
    final created = _now();
    ({ImportRead read, String? file}) course() {
      final read = readImport(text, created: created);
      return (
        read: read,
        file: read is ImportedChapters
            ? courseText(read, created: created)
            : null,
      );
    }

    final (:read, :file) = text.length < readOffThreadFrom
        ? course()
        : await Isolate.run(course);
    if (read is! ImportedChapters || file == null) {
      return const LibraryNothingToImport();
    }
    final folders = _freeNames(name);
    final staging = p.join(_root, '$stagingPrefix${_stagingId()}');
    final fileName = read.chapters.length == 1
        ? chapterFileNames(read.chapters).single
        : importedName(folders.first, fallback: 'Course');
    final ref = DocumentRef(p.join(staging, '$fileName.pgn'));
    final refused = switch (await _store.create(ref, file)) {
      store.Created() => null,
      store.Collision() => LibraryFailure('${ref.path} was already there'),
      store.IoFailure(:final detail) => LibraryFailure(detail),
    };
    if (refused != null) {
      await _files.removeStaging(staging);
      return refused;
    }
    return _placed(
      staging,
      folders,
      file: '$fileName.pgn',
      read: read,
      section: sectionsInText(file).first,
    );
  }

  /// [staging], holding [file], renamed into place under the first of
  /// [folders] that no folder on disk has taken.
  Future<LibraryResult> _placed(
    String staging,
    List<String> folders, {
    required String file,
    required ImportedChapters read,
    required String? section,
  }) async {
    for (final folder in folders) {
      final destination = p.join(_root, folder);
      switch (await _store.moveFolder(staging, destination)) {
        case store.FolderMoved():
          return LibraryAdded(
            ChapterRef.at(p.join(destination, file), section: section),
            chapters: read.chapters.length,
            lines: read.lines,
          );
        case store.FolderNameTaken():
          continue;
        case store.FolderMoveFailed(:final detail):
          await _files.removeStaging(staging);
          return LibraryFailure(detail);
      }
    }
    await _files.removeStaging(staging);
    return const LibraryNameTaken();
  }

  String _stagingId() =>
      DateTime.now().microsecondsSinceEpoch.toRadixString(36);
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

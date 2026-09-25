import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'directory_entries.dart';
import '../chess/pgn/chapter_heading.dart';
import '../chess/pgn/chapter_sections.dart';
import '../diagnostics/log.dart';
import 'document_ref.dart';
import 'recovery_gate.dart';
import 'relocation_notes.dart';
import 'pgn_document_store.dart' as store;
import 'document_relocation.dart' show recoveryFolder;

/// One chapter on disk: a file, or the games of a file that name one
/// chapter by tag ([section]), plus what the lists show about it without
/// opening it — its two names and its heading. The store takes it as the
/// [DocumentRef] it is, and two refs to one chapter are equal whatever their
/// headings say, because the path and the section are the identity.
final class ChapterRef extends DocumentRef {
  const ChapterRef({
    required this.repertoire,
    required this.name,
    required String path,
    this.heading = ChapterHeading.none,
    this.section,
  }) : super(path);

  /// The chapter a file path names: the file without `.pgn`, in the folder
  /// whose name is the repertoire's — or, with [section], the games of that
  /// file that carry that `[ChapterName]`, called by it. One rule, so a
  /// listing and a move cannot disagree about what a path means.
  factory ChapterRef.at(
    String path, {
    ChapterHeading heading = ChapterHeading.none,
    String? section,
  }) => ChapterRef(
    repertoire: p.basename(p.dirname(path)),
    name: section ?? p.basenameWithoutExtension(path),
    path: path,
    heading: heading,
    section: section,
  );

  /// The `[ChapterName]` its games carry, or null for the games of the file
  /// that carry none — every game, in a file of one chapter.
  @override
  final String? section;

  /// What the file as a whole is called: [name] for a file of one chapter,
  /// and for a chapter of a course file, the file's name without `.pgn`.
  String get fileName =>
      section == null ? name : p.basenameWithoutExtension(path);

  /// The file's own chapter: the same file, with no section.
  ChapterRef get wholeFile => section == null ? this : ChapterRef.at(path);

  /// The same chapter in the file at [path], which is where it went when its
  /// file was renamed or moved.
  ChapterRef inFile(String path) =>
      ChapterRef.at(path, heading: heading, section: section);

  /// Where the chapter starts and whether it is a draft, read off the top
  /// of the file when the folder was listed. A ref made from a path alone
  /// has [ChapterHeading.none].
  final ChapterHeading heading;

  /// The folder name under `repertoires/`.
  final String repertoire;

  /// The file name without `.pgn`.
  final String name;
}

/// One repertoire: a folder under `repertoires/` and the chapters in it.
final class RepertoireFolder {
  const RepertoireFolder({
    required this.name,
    required this.path,
    required this.modified,
    required this.chapters,
  });

  /// The folder's name, which is what the user called the repertoire.
  final String name;

  /// The folder itself, absolute.
  final String path;

  /// The newest change to any chapter in the folder, or to the folder when it
  /// holds none. Editing a chapter leaves the folder's own timestamp alone, so
  /// the folder's date by itself would say a repertoire in daily use was last
  /// touched the day it was made.
  final DateTime modified;

  final List<ChapterRef> chapters;
}

sealed class RepertoireListing {
  const RepertoireListing();
}

final class Repertoires extends RepertoireListing {
  const Repertoires(this.folders, {this.unreadable = const []});

  final List<RepertoireFolder> folders;

  /// The folders the listing had to pass over. One folder the operating
  /// system will not open is not a reason to show the user an empty library.
  final List<UnreadableFolder> unreadable;
}

/// A folder under `repertoires/` that could not be read, so whatever
/// chapters are in it are missing from the listing rather than deleted.
final class UnreadableFolder {
  const UnreadableFolder({
    required this.name,
    required this.path,
    required this.detail,
  });

  /// The folder's name, which is what the user called the repertoire.
  final String name;

  final String path;

  /// The operating system's message, for the log; the UI writes the sentence.
  final String detail;
}

/// The repertoires folder exists but could not be read.
final class RepertoiresUnreadable extends RepertoireListing {
  const RepertoiresUnreadable(this.detail);

  /// The operating system's message, for the log; the UI writes the sentence.
  final String detail;
}

/// The repertoire folders under `Documents/repertoires/`. The filesystem is a
/// real boundary, so this is an interface: [ChapterDirectory] in the app, a
/// scripted one in tests.
///
/// Listing and the one folder the library removes. A chapter's text is read,
/// and written, through the document store, which is the one place that knows
/// its revision.
abstract interface class ChapterFiles {
  Future<RepertoireListing> list();

  /// The chapters deleted from every repertoire and still in recovery,
  /// which is what a restore can bring back.
  Future<DeletedListing> deleted();

  /// Takes away a repertoire folder whose chapters have all been deleted, so
  /// deleting a repertoire leaves nothing behind in the user's Documents.
  ///
  /// A folder that still holds anything — a chapter this call did not expect,
  /// the recovery folder the deleted chapters went into — is left alone. It is
  /// then no longer a repertoire, because it has no chapters, and the list
  /// stops showing it either way.
  Future<void> removeIfEmpty(String folder);

  /// Takes away a staging folder an import made and could not finish, with
  /// whatever it had written into it. Only a folder the import named — a
  /// dot folder directly under the root — is ever removed; anything else is
  /// left alone, because nothing but an import should be deleting a folder.
  Future<void> removeStaging(String folder);
}

/// What an import's staging folder is called: a dot folder, which the
/// listing skips, so a half-written import is never a repertoire.
const stagingPrefix = '.import-';

/// One folder per repertoire, one `.pgn` per chapter, plus index files and
/// sidecars the app ignores.
final class ChapterDirectory implements ChapterFiles {
  ChapterDirectory(
    this.root, {
    required RecoveryGate recovery,
    store.PgnDocumentStore? documents,
  }) : _recovery = recovery,
       _documents = documents;

  final RecoveryGate _recovery;

  final store.PgnDocumentStore? _documents;

  /// The `repertoires` directory itself.
  final Directory root;

  /// The chapter names each file was last found to hold, with the size and
  /// time it had then: a course is one file of thousands of games, and the
  /// library is listed again after every write.
  final _sections =
      <String, ({int size, DateTime modified, List<String?> names})>{};

  @override
  Future<RepertoireListing> list() async {
    try {
      // Migration calls the public store between scans, never while holding
      // its non-reentrant recovery domain. Both scans observe a settled tree.
      await _migrateFlat();
      return await _recovery.run(() async {
        if (!await root.exists()) return const Repertoires([]);
        final skipped = <UnreadableFolder>[];
        final folders = await _scan(skipped);
        folders.sort(_byName);
        return Repertoires(
          List.unmodifiable(folders),
          unreadable: List.unmodifiable(skipped),
        );
      });
    } on RecoveryRequired catch (error) {
      return RepertoiresUnreadable(error.detail);
    } on FileSystemException catch (error) {
      return RepertoiresUnreadable(_detail(error));
    }
  }

  @override
  Future<DeletedListing> deleted() async {
    try {
      return await _recovery.run(() => listDeleted(root));
    } on RecoveryRequired catch (error) {
      return DeletedUnreadable(error.detail);
    } on FileSystemException catch (error) {
      return DeletedUnreadable(_detail(error));
    }
  }

  @override
  Future<void> removeIfEmpty(String folder) =>
      _cleanup(folder, () => _removeIfEmpty(folder));

  Future<void> _removeIfEmpty(String folder) async {
    final directory = Directory(folder);
    try {
      if (await directoryEntries(directory).isEmpty) await directory.delete();
    } on FileSystemException catch (error) {
      log.w('remove the empty folder $folder', error);
    }
  }

  @override
  Future<void> removeStaging(String folder) =>
      _cleanup(folder, () => _removeStaging(folder));

  // Cleanup is optional. Preserve the directory when recovery is blocked,
  // without replacing the command's original typed failure with an exception.
  Future<void> _cleanup(String folder, Future<void> Function() action) async {
    try {
      await _recovery.run(action);
    } on RecoveryRequired catch (error) {
      log.w('clean up $folder', error);
    } on FileSystemException catch (error) {
      log.w('clean up $folder', error);
    }
  }

  Future<void> _removeStaging(String folder) async {
    if (!p.equals(p.dirname(folder), root.path) ||
        !p.basename(folder).startsWith(stagingPrefix)) {
      log.w('remove the staging folder $folder', 'it is not a staging folder');
      return;
    }
    try {
      final directory = Directory(folder);
      if (await directory.exists()) await directory.delete(recursive: true);
    } on FileSystemException catch (error) {
      log.w('remove the staging folder $folder', error);
    }
  }

  Future<void> _migrateFlat() async {
    final documents = _documents;
    if (documents == null) return;
    final entries = await _recovery.run(
      () async => await root.exists()
          ? await directoryEntries(root, followLinks: false).toList()
          : <FileSystemEntity>[],
    );
    for (final entry in entries) {
      if (entry is! File ||
          p.basename(entry.path).startsWith('.') ||
          !_isChapter(entry.path))
        continue;
      final ref = DocumentRef(entry.path);
      final read = await documents.open(ref);
      if (read is! store.Opened) continue;
      final destination = p.join(
        root.path,
        p.basenameWithoutExtension(entry.path),
        'Main.pgn',
      );
      final result = await documents.move(
        ref,
        DocumentRef(destination),
        expected: read.revision,
      );
      if (result is! store.Moved) log.w('migrate ${entry.path}', '$result');
    }
  }

  Future<List<RepertoireFolder>> _scan(List<UnreadableFolder> skipped) async {
    final folders = <RepertoireFolder>[];
    await for (final entry in directoryEntries(root, followLinks: false)) {
      if (p.basename(entry.path).startsWith('.')) continue;
      if (entry is File && _isChapter(entry.path)) {
        final stat = await entry.stat();
        folders.add(
          RepertoireFolder(
            name: p.basenameWithoutExtension(entry.path),
            path: entry.path,
            modified: stat.modified,
            chapters: [
              for (final section in await _sectionsOf(entry, stat))
                ChapterRef.at(
                  entry.path,
                  section: section,
                  heading: await _headingOf(entry),
                ),
            ],
          ),
        );
        continue;
      }
      if (entry is! Directory) continue;
      final name = p.basename(entry.path);
      if (name.startsWith('.')) continue;
      // One folder the app may not open is that repertoire's problem, not
      // the library's: the others are still listed and the user is told
      // which one is missing.
      final RepertoireFolder folder;
      try {
        folder = await _read(entry, name);
      } on FileSystemException catch (error) {
        log.w('list the repertoire ${entry.path}', error);
        skipped.add(
          UnreadableFolder(
            name: name,
            path: entry.path,
            detail: _detail(error),
          ),
        );
        continue;
      }
      // A folder with no chapters is not a repertoire. It is what a deleted
      // one leaves behind — the recovery folder its chapters went into — and
      // showing "0 chapters" after a delete would say the delete failed.
      if (folder.chapters.isNotEmpty) folders.add(folder);
    }
    return folders;
  }

  Future<RepertoireFolder> _read(Directory folder, String name) async {
    final files = <File>[];
    var modified = (await folder.stat()).modified;
    await for (final file in _chapterFiles(folder)) {
      files.add(file);
    }
    files.sort(_byFileName);
    final chapters = <ChapterRef>[];
    for (final file in files) {
      final stat = await file.stat();
      if (stat.modified.isAfter(modified)) modified = stat.modified;
      final heading = await _headingOf(file);
      // A file's chapters are listed in the order the file gives them.
      for (final section in await _sectionsOf(file, stat)) {
        chapters.add(
          ChapterRef(
            repertoire: name,
            name: section ?? p.basenameWithoutExtension(file.path),
            path: file.path,
            heading: heading,
            section: section,
          ),
        );
      }
    }
    return RepertoireFolder(
      name: name,
      path: folder.path,
      modified: modified,
      chapters: List.unmodifiable(chapters),
    );
  }
}

/// Traverse shelves without following links or visiting recovery/staging data.
Stream<File> _chapterFiles(Directory folder) async* {
  await for (final entry in directoryEntries(folder, followLinks: false)) {
    if (p.basename(entry.path).startsWith('.')) continue;
    if (entry is Directory) {
      yield* _chapterFiles(entry);
    } else if (entry is File && _isChapter(entry.path)) {
      yield entry;
    }
  }
}

extension on ChapterDirectory {
  /// The chapter names [file] holds, from the cache while the file is as it
  /// was. A file that cannot be read lists as one chapter; opening it is
  /// where the user is told why.
  Future<List<String?>> _sectionsOf(File file, FileStat stat) async {
    final known = _sections[file.path];
    if (known != null &&
        known.size == stat.size &&
        known.modified == stat.modified) {
      return known.names;
    }
    List<String?> names = const [null];
    try {
      final text = utf8.decode(await file.readAsBytes(), allowMalformed: true);
      if (text.contains('[$chapterNameTag ')) names = sectionsInText(text);
    } on FileSystemException catch (error) {
      log.w('read the chapters of ${file.path}', error);
    }
    _sections[file.path] = (
      size: stat.size,
      modified: stat.modified,
      names: names,
    );
    return names;
  }
}

/// The `//` lines above the first game, read off the top of the file: a
/// chapter of ten thousand lines costs the listing one kilobyte, not the
/// file. A file that cannot be read here still lists; opening it is where
/// the user is told why.
Future<ChapterHeading> _headingOf(File file) async {
  try {
    final head = await file.openRead(0, _headingBytes).toList();
    return readHeading(
      utf8.decode(head.expand((chunk) => chunk).toList(), allowMalformed: true),
    );
  } on FileSystemException catch (error) {
    log.w('read the heading of ${file.path}', error);
    return ChapterHeading.none;
  }
}

/// More than any heading the old app writes; a preamble longer than this
/// loses its root line to the list, not to the chapter.
const _headingBytes = 1024;

/// A chapter is a `.pgn` that is not one of the raw-game sidecars generation
/// writes beside a chapter; the old app hides those from its list too.
bool _isChapter(String path) =>
    p.extension(path) == '.pgn' && !path.endsWith('_raw_games.pgn');

String _detail(FileSystemException e) => e.osError?.message ?? e.message;

int _byName(RepertoireFolder a, RepertoireFolder b) =>
    a.name.toLowerCase().compareTo(b.name.toLowerCase());

int _byFileName(File a, File b) => p
    .basenameWithoutExtension(a.path)
    .toLowerCase()
    .compareTo(p.basenameWithoutExtension(b.path).toLowerCase());

// The chapters the user deleted, which are still on disk: a delete moves a
// chapter into the recovery folder beside it (`document_relocation.dart`)
// under `<microseconds>-<token>-<file name>`, the name both apps give it.

/// One deleted chapter file, and where it came from.
final class DeletedChapter {
  const DeletedChapter({
    required this.path,
    required this.folder,
    required this.name,
    required this.deletedAt,
  });

  /// The file in the recovery folder, absolute.
  final String path;

  /// The repertoire folder the chapter was deleted from, absolute. The
  /// recovery folder is inside it, so it is still there even when every
  /// chapter of the repertoire was deleted.
  final String folder;

  /// The chapter's name when it was deleted: its file name without `.pgn`.
  final String name;

  /// When it was deleted, read off its recovery name.
  final DateTime deletedAt;

  /// The repertoire's name, which is its folder's.
  String get repertoire => p.basename(folder);

  /// Where restoring it as [as] puts it: back in its folder, under its old
  /// name unless the user chose another.
  String restoredAs([String? as]) => p.join(folder, '${as ?? name}.pgn');
}

sealed class DeletedListing {
  const DeletedListing();
}

/// Every deleted chapter found, the most recently deleted first.
final class DeletedChapters extends DeletedListing {
  const DeletedChapters(this.chapters);

  final List<DeletedChapter> chapters;
}

/// The repertoires folder could not be read.
final class DeletedUnreadable extends DeletedListing {
  const DeletedUnreadable(this.detail);

  /// The operating system's message, for the log; the UI writes the sentence.
  final String detail;
}

/// The chapters in the recovery folder of every repertoire under [root].
///
/// Only chapter files are listed: the recovery folder also holds the old
/// app's kept versions (`<digest>.bytes`) and whatever else a lock left
/// there. A repertoire whose recovery folder cannot be read is passed over
/// with a log line, as the repertoire listing passes over a folder.
Future<DeletedListing> listDeleted(Directory root) async {
  if (!await root.exists()) return const DeletedChapters([]);
  final found = <DeletedChapter>[];
  try {
    await for (final entry in directoryEntries(root, followLinks: false)) {
      if (entry is! Directory || p.basename(entry.path).startsWith('.')) {
        continue;
      }
      found.addAll(await _deletedBelow(entry));
    }
  } on FileSystemException catch (error) {
    log.w('list the deleted chapters under ${root.path}', error);
    return DeletedUnreadable(error.osError?.message ?? error.message);
  }
  found.sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
  return DeletedChapters(List.unmodifiable(found));
}

Future<List<DeletedChapter>> _deletedBelow(Directory directory) async {
  final found = await _deletedIn(directory.path);
  await for (final entry in directoryEntries(directory, followLinks: false)) {
    if (entry is Directory && !p.basename(entry.path).startsWith('.')) {
      found.addAll(await _deletedBelow(entry));
    }
  }
  return found;
}

Future<List<DeletedChapter>> _deletedIn(String folder) async {
  final trash = Directory(p.join(folder, recoveryFolder));
  final found = <DeletedChapter>[];
  try {
    if (!await trash.exists()) return found;
    await for (final entry in directoryEntries(trash)) {
      if (entry is! File) continue;
      final chapter = readRecoveryName(entry.path, folder: folder);
      if (chapter != null) found.add(chapter);
    }
  } on FileSystemException catch (error) {
    log.w('list the deleted chapters in $folder', error);
  }
  return found;
}

/// The deleted chapter a recovery file at [path] is, or null when its name
/// is not one a delete gives: `<microseconds>-<hex token>-<name>.pgn`, and
/// not a raw-game sidecar, which was never a chapter.
DeletedChapter? readRecoveryName(String path, {required String folder}) {
  final match = _recoveryName.firstMatch(p.basename(path));
  if (match == null) return null;
  final name = match.group(2)!;
  if (name.endsWith('_raw_games')) return null;
  return DeletedChapter(
    path: path,
    folder: folder,
    name: name,
    deletedAt: DateTime.fromMicrosecondsSinceEpoch(int.parse(match.group(1)!)),
  );
}

final _recoveryName = RegExp(r'^(\d{1,17})-[0-9a-f]+-(.+)\.pgn$');

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import 'directory_entries.dart';
import '../chess/pgn/chapter_heading.dart';
import '../chess/pgn/chapter.dart' show readOffThreadFrom;
import 'document_probe.dart';
import '../chess/pgn/chapter_sections.dart';
import '../diagnostics/log.dart';
import 'document_ref.dart';
import 'recovery_gate.dart';
import 'relocation_notes.dart';
import 'pgn_document_store.dart' as store;

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
  const Repertoires(
    this.folders, {
    this.unreadable = const [],
    this.revisions = const {},
  });

  /// Complete native read set, including draft chapters. Successful native
  /// listings own an immutable map; no PGN text survives metadata parsing.
  final Map<String, Revision> revisions;

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
/// Listing and optional folder cleanup share the document store's recovery
/// domain. Native membership and metadata observations use the same file
/// revision proof as document reads.
abstract interface class ChapterFiles {
  Future<RepertoireListing> list();

  /// Checks complete membership and native revisions together under one
  /// recovery domain. [observed] names additional reads used by a projection;
  /// each must describe the same file as the listing. [additional] captures
  /// related managed PGNs, such as downloaded games; null means absent. All
  /// are validated under the same domain. Never nest guarded store calls.
  Future<RepertoireValidation> validate(
    Repertoires snapshot, {
    required Map<String, Revision> observed,
    Map<String, Revision?> additional = const {},
  });

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

sealed class RepertoireValidation {
  const RepertoireValidation();
}

final class RepertoireCurrent extends RepertoireValidation {
  const RepertoireCurrent();
}

final class RepertoireChanged extends RepertoireValidation {
  const RepertoireChanged();
}

final class RepertoireValidationFailed extends RepertoireValidation {
  const RepertoireValidationFailed(this.detail);
  final String detail;
}

/// Revision equality is deliberately content-only for saving. A projection
/// also needs the native object that supplied those bytes.
bool sameChapterRevision(Revision first, Revision second) =>
    first == second && first.nativeIdentity == second.nativeIdentity;

/// What an import's staging folder is called: a dot folder, which the
/// listing skips, so a half-written import is never a repertoire.
const stagingPrefix = '.import-';

/// One folder per repertoire, one `.pgn` per chapter, plus index files and
/// sidecars the app ignores.
final class ChapterDirectory implements ChapterFiles {
  ChapterDirectory(this.root, {required this._recovery, this._documents});

  final RecoveryGate _recovery;

  final store.PgnDocumentStore? _documents;

  /// The `repertoires` directory itself.
  final Directory root;

  var _metadata = <String, ({Revision revision, _Metadata value})>{};

  @override
  Future<RepertoireListing> list() async {
    try {
      // Migration uses the public store outside the non-reentrant domain.
      await _migrateFlat();
      final captured = await _recovery.run(_capture);
      final listing = await _listingOf(captured);
      // An incomplete listing remains diagnostic, never a complete snapshot.
      if (listing.unreadable.isNotEmpty) return listing;
      return switch (await validate(listing, observed: const {})) {
        RepertoireCurrent() => listing,
        RepertoireChanged() => const RepertoiresUnreadable(
          'The repertoire files changed while they were being read. Refresh to retry.',
        ),
        RepertoireValidationFailed(:final detail) => RepertoiresUnreadable(
          detail,
        ),
      };
    } on RecoveryRequired catch (error) {
      return RepertoiresUnreadable(error.detail);
    } on FileSystemException catch (error) {
      return RepertoiresUnreadable(_detail(error));
    } on FormatException catch (error) {
      return RepertoiresUnreadable(error.message);
    }
  }

  @override
  Future<RepertoireValidation> validate(
    Repertoires snapshot, {
    required Map<String, Revision> observed,
    Map<String, Revision?> additional = const {},
  }) async {
    if (snapshot.unreadable.isNotEmpty) {
      return RepertoireValidationFailed(snapshot.unreadable.first.detail);
    }
    final reads = Map<String, Revision>.unmodifiable(observed);
    final related = Map<String, Revision?>.unmodifiable(additional);
    try {
      return await _recovery.run(() async {
        final inventory = await _inventory();
        if (inventory.unreadable.isNotEmpty) {
          return RepertoireValidationFailed(inventory.unreadable.first.detail);
        }
        final paths = [for (final folder in inventory.folders) ...folder.files];
        if (paths.length != snapshot.revisions.length ||
            paths.any((file) => !snapshot.revisions.containsKey(file.path))) {
          return const RepertoireChanged();
        }
        for (final entry in reads.entries) {
          final captured = snapshot.revisions[entry.key];
          if (captured == null || !sameChapterRevision(captured, entry.value)) {
            return const RepertoireChanged();
          }
        }
        for (final file in paths) {
          switch (await probeDocument(file.path)) {
            case FileFound(:final revision):
              if (!sameChapterRevision(
                snapshot.revisions[file.path]!,
                revision,
              )) {
                return const RepertoireChanged();
              }
            case FileMissing():
              return const RepertoireChanged();
            case FileUnreadable(:final detail):
              return RepertoireValidationFailed('${file.path}: $detail');
          }
        }
        return _validateAdditional(related);
      });
    } on RecoveryRequired catch (error) {
      return RepertoireValidationFailed(error.detail);
    } on FileSystemException catch (error) {
      return RepertoireValidationFailed(_detail(error));
    }
  }

  Future<RepertoireValidation> _validateAdditional(
    Map<String, Revision?> additional,
  ) async {
    for (final entry in additional.entries) {
      final path = entry.key;
      if (!await _managedRelatedPgn(path)) {
        return const RepertoireValidationFailed(
          'Related snapshot files must be managed PGNs without linked descendants.',
        );
      }
      final expected = entry.value;
      switch (await probeDocument(path)) {
        case FileFound(:final revision):
          if (expected == null || !sameChapterRevision(expected, revision)) {
            return const RepertoireChanged();
          }
        case FileMissing():
          if (expected != null) return const RepertoireChanged();
        case FileUnreadable(:final detail):
          return RepertoireValidationFailed('$path: $detail');
      }
    }
    return const RepertoireCurrent();
  }

  Future<bool> _managedRelatedPgn(String path) async {
    final documents = p.normalize(_recovery.documents.absolute.path);
    if (!p.isAbsolute(path) ||
        p.normalize(path) != path ||
        path.contains('\u0000') ||
        p.extension(path).toLowerCase() != '.pgn' ||
        !p.isWithin(documents, path)) {
      return false;
    }
    // A configured root alias is valid. Descendant aliases could enter a
    // different profile whose writers do not share the domain held here.
    var parent = p.dirname(path);
    while (p.isWithin(documents, parent)) {
      final type = await FileSystemEntity.type(parent, followLinks: false);
      if (type != FileSystemEntityType.directory &&
          type != FileSystemEntityType.notFound) {
        return false;
      }
      parent = p.dirname(parent);
    }
    return true;
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
          !_isChapter(entry.path)) {
        continue;
      }
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

  Future<_Inventory> _inventory() async {
    final folders = <_FolderFiles>[];
    final unreadable = <UnreadableFolder>[];
    if (!await root.exists()) return (folders: folders, unreadable: unreadable);
    await for (final entry in directoryEntries(root, followLinks: false)) {
      if (p.basename(entry.path).startsWith('.')) continue;
      if (entry is Link) {
        unreadable.add(
          UnreadableFolder(
            name: p.basename(entry.path),
            path: entry.path,
            detail:
                'Linked repertoire content cannot be included in a complete snapshot.',
          ),
        );
        continue;
      }
      if (entry is File && _isChapter(entry.path)) {
        folders.add((
          path: entry.path,
          name: p.basenameWithoutExtension(entry.path),
          modified: (await entry.stat()).modified,
          files: [entry],
        ));
      } else if (entry is Directory) {
        try {
          final files = await _chapterFiles(entry).toList();
          files.sort(_byFileName);
          folders.add((
            path: entry.path,
            name: p.basename(entry.path),
            modified: (await entry.stat()).modified,
            files: files,
          ));
        } on FileSystemException catch (error) {
          unreadable.add(
            UnreadableFolder(
              name: p.basename(entry.path),
              path: entry.path,
              detail: _detail(error),
            ),
          );
        }
      }
    }
    return (folders: folders, unreadable: unreadable);
  }

  Future<_CapturedLibrary> _capture() async {
    final inventory = await _inventory();
    final documents = <String, _CapturedChapter>{};
    for (final folder in inventory.folders) {
      for (final file in folder.files) {
        final observed = await probeDocument(file.path);
        if (observed is! FileFound) {
          throw FileSystemException(
            'Cannot read a complete repertoire snapshot',
            file.path,
          );
        }
        documents[file.path] = (
          revision: observed.revision,
          modified: (await file.stat()).modified,
        );
      }
    }
    return (inventory: inventory, documents: documents);
  }

  Future<_Metadata> _metadataOf(String path, Revision expected) async {
    final observed = await _recovery.run(() => probeDocument(path));
    if (observed is! FileFound) {
      throw FileSystemException('Cannot read chapter metadata', path);
    }
    if (!sameChapterRevision(expected, observed.revision)) {
      throw FileSystemException(
        'The repertoire files changed while reading metadata. Refresh to retry.',
        path,
      );
    }
    return _readMetadata(utf8.decode(observed.bytes));
  }

  /// Metadata parsing happens after capture releases the recovery domain.
  /// Only one uncached PGN is materialized at a time, against its captured
  /// proof. Content-addressed metadata is cached, bounded to this listing.
  Future<Repertoires> _listingOf(_CapturedLibrary captured) async {
    final folders = <RepertoireFolder>[];
    final metadata = <String, ({Revision revision, _Metadata value})>{};
    for (final folder in captured.inventory.folders) {
      final chapters = <ChapterRef>[];
      var modified = folder.modified;
      for (final file in folder.files) {
        final read = captured.documents[file.path]!;
        if (read.modified.isAfter(modified)) modified = read.modified;
        final known = _metadata[file.path];
        final value = known?.revision == read.revision
            ? known!.value
            : await _metadataOf(file.path, read.revision);
        metadata[file.path] = (revision: read.revision, value: value);
        for (final section in value.names) {
          chapters.add(
            ChapterRef(
              repertoire: folder.name,
              name: section ?? p.basenameWithoutExtension(file.path),
              path: file.path,
              heading: value.heading,
              section: section,
            ),
          );
        }
      }
      if (chapters.isNotEmpty) {
        folders.add(
          RepertoireFolder(
            name: folder.name,
            path: folder.path,
            modified: modified,
            chapters: List.unmodifiable(chapters),
          ),
        );
      }
    }
    folders.sort(_byName);
    _metadata = metadata;
    return Repertoires(
      List.unmodifiable(folders),
      unreadable: List.unmodifiable(captured.inventory.unreadable),
      revisions: Map.unmodifiable({
        for (final entry in captured.documents.entries)
          entry.key: entry.value.revision,
      }),
    );
  }
}

typedef _FolderFiles = ({
  String path,
  String name,
  DateTime modified,
  List<File> files,
});
typedef _Inventory = ({
  List<_FolderFiles> folders,
  List<UnreadableFolder> unreadable,
});
typedef _CapturedChapter = ({Revision revision, DateTime modified});
typedef _CapturedLibrary = ({
  _Inventory inventory,
  Map<String, _CapturedChapter> documents,
});
typedef _Metadata = ({List<String?> names, ChapterHeading heading});

Future<_Metadata> _readMetadata(String text) async {
  _Metadata parse() {
    final heading = readHeading(text);
    return (
      names: List.unmodifiable(
        text.contains('[$chapterNameTag ')
            ? sectionsInText(text)
            : <String?>[null],
      ),
      heading: ChapterHeading(
        rootMoves: List.unmodifiable(heading.rootMoves),
        draft: heading.draft,
      ),
    );
  }

  return text.length < readOffThreadFrom ? parse() : Isolate.run(parse);
}

/// Traverse shelves without following links or visiting recovery/staging data.
Stream<File> _chapterFiles(Directory folder) async* {
  await for (final entry in directoryEntries(folder, followLinks: false)) {
    if (p.basename(entry.path).startsWith('.')) continue;
    // A link may name an entire subtree. Do not follow it or quietly certify
    // a complete inventory without knowing the chapters it hides.
    if (entry is Link) {
      throw FileSystemException(
        'Linked repertoire content cannot be listed',
        entry.path,
      );
    }
    if (entry is Directory) {
      yield* _chapterFiles(entry);
    } else if (entry is File && _isChapter(entry.path)) {
      yield entry;
    }
  }
}

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
// chapter into the recovery folder beside it (`relocation_notes.dart`)
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

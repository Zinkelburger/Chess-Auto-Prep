import 'package:path/path.dart' as p;

import 'book_snapshot.dart';
import 'training_snapshot.dart';
import 'game_store.dart';
import '../chess/pgn/chapter_heading.dart';
import 'deleted_chapters.dart';
import 'document_ref.dart';

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
    this.boundaries,
  });

  /// Null captures the whole catalog. Otherwise membership is complete only
  /// under these absolute directories or individual PGNs, including absence.
  final Set<String>? boundaries;

  bool includesPath(String path) =>
      boundaries == null ||
      boundaries!.any((root) => root == path || p.isWithin(root, path));

  bool intersectsPath(String path) =>
      includesPath(path) ||
      (boundaries?.any((root) => p.isWithin(path, root)) ?? false);

  /// Keeps exactly the membership a projection depends on. The final storage
  /// fence still discovers newly created/deleted files under these boundaries.
  Repertoires within(Set<String> paths) {
    final bounds = Set<String>.unmodifiable(paths);
    bool includes(String path) =>
        bounds.any((root) => path == root || p.isWithin(root, path));
    return Repertoires(
      List.unmodifiable([
        for (final folder in folders)
          if (includes(folder.path) ||
              folder.chapters.any((ref) => includes(ref.path)))
            RepertoireFolder(
              name: folder.name,
              path: folder.path,
              modified: folder.modified,
              chapters: List.unmodifiable(
                folder.chapters.where((ref) => includes(ref.path)),
              ),
            ),
      ]),
      unreadable: List.unmodifiable(
        unreadable.where(
          (entry) =>
              includes(entry.path) ||
              bounds.any((root) => p.isWithin(entry.path, root)),
        ),
      ),
      revisions: Map.unmodifiable({
        for (final entry in revisions.entries)
          if (includes(entry.key)) entry.key: entry.value,
      }),
      boundaries: bounds,
    );
  }

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
  /// are validated under the same domain. A null snapshot validates the used
  /// PGNs without whole-repertoire membership (a single-chapter scope). Book
  /// and training proofs address only their fixed configured profile files.
  /// Never nest guarded store calls.
  /// [archive] adds the optional SQLite selected-corpus transaction to this
  /// same final guard; it is a logical row proof, not a database-file hash.
  Future<RepertoireValidation> validate(
    Repertoires? snapshot, {
    required Map<String, Revision> observed,
    Map<String, Revision?> additional = const {},
    BookSource? book,
    TrainingReadSet? training,
    StoredGamesSource? archive,
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

  /// Takes away the chapter file at [ref] that a change created a moment
  /// ago as [created] and then could not use, without a recovery copy:
  /// nobody has seen it, and it holds nothing but what was written. A file
  /// whose bytes are no longer [created] is left alone. True when the file
  /// is gone; a failure is logged.
  Future<bool> removeUnused(DocumentRef ref, Revision created);
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

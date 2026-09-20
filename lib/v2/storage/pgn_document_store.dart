import 'document_ref.dart';
import 'edit_scope.dart';
import 'training_records.dart';

/// The one way `v2` writes a PGN file. The filesystem is a real boundary, so
/// this is an interface: [PgnFileStore] in the app, a scripted one in tests.
///
/// Every mutation names the [Revision] the caller last read. If the bytes on
/// disk are no longer that revision, the store refuses and says what is there
/// now; there is no flag that turns the refusal off. What the caller does with
/// the refusal — keep editing, save a copy, reload — is the workspace's
/// business, and the draft is never this store's to throw away.
abstract interface class PgnDocumentStore {
  /// Reads [ref]. A failed read is never an empty document.
  Future<DocumentRead> open(DocumentRef ref);

  /// Writes a document that does not exist yet. Replaces nothing: if the name
  /// is taken, even by a file created a moment ago, this is a [Collision].
  ///
  /// There is no [EditScope] here and nothing to compare against: a create
  /// replaces no version, so there is no game of anybody's it could damage.
  Future<CreateResult> create(DocumentRef ref, String text);

  /// Replaces [ref] with [text], having read [expected].
  ///
  /// [scope] says which games of the version on disk this save means to
  /// change. A save whose text would change any other game is refused before
  /// anything is written; a caller that cannot say passes [WholeDocument]
  /// and the store logs that it did.
  Future<SaveResult> save(
    DocumentRef ref,
    String text, {
    required Revision expected,
    required EditScope scope,
  });

  /// Gives [ref] a new file name, such as `Main.pgn`, in the same folder.
  Future<MoveResult> rename(
    DocumentRef ref,
    String name, {
    required Revision expected,
  });

  /// Moves [ref] to [destination], replacing nothing.
  Future<MoveResult> move(
    DocumentRef ref,
    DocumentRef destination, {
    required Revision expected,
  });

  /// Moves the folder at [from] to [to] with everything in it, in one
  /// exclusive rename.
  ///
  /// A repertoire is a folder: chapters, the raw-game sidecars written beside
  /// them and the generation bundles under it. Moving it a document at a time
  /// could stop half way and leave one repertoire in two folders with the
  /// rest of its files stranded, so this moves all of it or none of it. There
  /// is no revision to name, because the documents inside are not read or
  /// written — only the name of the folder above them changes.
  Future<FolderMoveResult> moveFolder(String from, String to);

  /// Moves [ref] into the recovery folder the old app also deletes into, so
  /// the user has one place to look and nothing is unlinked.
  Future<DeleteResult> delete(DocumentRef ref, {required Revision expected});
}

sealed class DocumentRead {
  const DocumentRead();
}

final class Opened extends DocumentRead {
  const Opened(this.text, this.revision);

  final String text;
  final Revision revision;
}

final class Absent extends DocumentRead {
  const Absent();
}

final class Unreadable extends DocumentRead {
  const Unreadable(this.detail);

  /// For the log; the widget writes the sentence.
  final String detail;
}

/// What a completed save replaced, and what it committed.
///
/// This is the whole of undo: `save(receipt.before, expected: receipt.committed)`
/// puts the previous version back, and returns a receipt of its own. If
/// something else wrote in between, that save is a [Conflict] and the entry
/// stays where it is — an undo never guesses.
final class Receipt {
  const Receipt({
    required this.committed,
    required this.before,
    required this.beforeRevision,
  });

  /// The revision the file now has.
  final Revision committed;

  /// The exact text that was replaced, as it was read from disk.
  final String before;

  final Revision beforeRevision;
}

sealed class CreateResult {
  const CreateResult();
}

sealed class SaveResult {
  const SaveResult();
}

sealed class MoveResult {
  const MoveResult();
}

sealed class DeleteResult {
  const DeleteResult();
}

sealed class FolderMoveResult {
  const FolderMoveResult();
}

/// The folder and everything under it is at the new path.
final class FolderMoved extends FolderMoveResult {
  const FolderMoved({this.training = const NothingToRepoint()});

  /// Whether the training rows naming documents inside the folder followed
  /// it. One answer for the whole folder: the rows are rewritten in one pass.
  final RepointResult training;
}

/// Something of that name is already there. Nothing was moved.
final class FolderNameTaken extends FolderMoveResult {
  const FolderNameTaken();
}

/// The folder could not be moved. It is where it was, whole.
final class FolderMoveFailed extends FolderMoveResult {
  const FolderMoveFailed(this.detail);

  /// For the log; the widget writes the sentence.
  final String detail;
}

final class Created implements CreateResult {
  const Created(this.revision);

  final Revision revision;
}

final class Saved implements SaveResult {
  const Saved(this.receipt);

  final Receipt receipt;
}

final class Moved implements MoveResult {
  const Moved(this.revision, {this.training = const NothingToRepoint()});

  /// Unchanged by the move: the same bytes in the same file, under a new name.
  final Revision revision;

  /// Whether the training rows that named the old path followed it. The file
  /// is not put back when they did not: it is where the user asked for it,
  /// and this says what is still pointing at the name it left.
  final RepointResult training;
}

final class Deleted implements DeleteResult {
  const Deleted(this.recoveredTo, {this.training = const NothingToRepoint()});

  /// Where the file now is, so the user can be told where to find it.
  final String recoveredTo;

  /// Whether the training rows followed the chapter into recovery, so a
  /// restore brings its schedule back with it.
  final RepointResult training;
}

/// The name is taken. Nothing was written.
final class Collision implements CreateResult, MoveResult {
  const Collision();
}

/// The file is not the revision the caller read.
final class Conflict implements SaveResult, MoveResult, DeleteResult {
  const Conflict(this.current);

  /// What is on disk now, or null when the document is gone.
  final Revision? current;
}

/// A save that did not put the words on disk, for a reason that is not
/// somebody else writing the file first. The draft is still the user's and
/// the document is not saved.
sealed class SaveDidNotLand implements SaveResult {
  const SaveDidNotLand(this.detail);

  /// For the log; the widget writes the sentence.
  final String detail;
}

/// The text would have changed a game the save did not declare, so nothing
/// was written. The file and the versions kept for it are as they were.
///
/// This is a mistake in whatever produced the text rather than anything the
/// user did or can fix by trying again, so [detail] names the game that
/// would have changed and what the save said it was changing.
final class SaveRefused extends SaveDidNotLand {
  const SaveRefused(super.detail);
}

/// The bytes were written and the file does not hold them.
///
/// The version this write replaced is kept, and [detail] says where, so the
/// document can be put back by hand until the restore screen exists.
final class WriteUnverified extends SaveDidNotLand {
  const WriteUnverified(super.detail);
}

/// The operation could not be carried out. The document is as it was.
final class IoFailure extends SaveDidNotLand
    implements CreateResult, MoveResult, DeleteResult {
  const IoFailure(super.detail);
}

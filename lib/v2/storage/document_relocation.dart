/// Folder moves still using the original relocation note. File rename,
/// move, delete and restore use FileRelocations for their complete read set.
library;

import 'dart:io';

import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import 'directory_entries.dart';
import '../diagnostics/log.dart';
import 'backups.dart';
import 'document_ref.dart';
import 'mutation_guards.dart';
import 'relocation_notes.dart';
import 'pgn_document_store.dart';

/// The remaining folder commands of [PgnDocumentStore], over the same
/// Documents root, kept versions and training records. Its caller must already hold `RecoveryGate` for this profile;
/// this adapter takes only the inner Documents and leaf locks.
final class DocumentRelocation {
  DocumentRelocation({
    required this.documents,
    required BackupArchive backups,
    required RelocationNotes notes,
  }) : _backups = backups,
       _notes = notes;

  /// The folder every document lives under; a ref outside it is refused.
  final Directory documents;

  final BackupArchive _backups;
  final RelocationNotes _notes;

  /// Moves a whole folder of documents — a repertoire — in one rename.
  ///
  /// All v2 mutations take the documents root before their leaf folders.
  /// This also protects nested chapters: locking only the repertoire folder
  /// would miss a writer holding a lock on one of its descendants. Leaf
  /// locks remain necessary for interoperability with legacy direct writers.
  ///
  /// The kept versions follow each document inside, because a document's
  /// history is kept under a hash of its path rather than under its folder's;
  /// a history that cannot be moved is left where it is and never fails the
  /// move, exactly as it does for one document.
  Future<FolderMoveResult> moveFolder(String from, String to) =>
      lockedForRelocation(
        documents,
        DocumentRef(from),
        [Directory(from), Directory(to)],
        () => _moveFolderAndRepoint(from, to),
        FolderMoveFailed.new,
      );

  /// `repoint` rewrites every row inside a folder that moved, not just the
  /// rows that name it exactly.
  Future<FolderMoveResult> _moveFolderAndRepoint(String from, String to) async {
    final note = newMoveNote();
    final result = await _moveFolder(note, from, to);
    if (result is FolderMoved) {
      return FolderMoved(
        training: await _notes.repoint(
          note,
          DocumentRef(from),
          DocumentRef(to),
        ),
      );
    }
    return result;
  }

  Future<FolderMoveResult> _moveFolder(
    String note,
    String from,
    String to,
  ) async {
    if (!p.isWithin(documents.path, from) || !p.isWithin(documents.path, to)) {
      return const FolderMoveFailed(outsideRoot);
    }
    // Read before the move, because afterwards the old names are gone.
    final documentNames = await _documentsIn(from);
    if (documentNames == null) return const FolderMoveFailed(_unlistable);
    final identity = (await observeDirectory(from)).identity;
    if (identity == null) return const FolderMoveFailed(_unidentifiable);
    try {
      await _notes.record(
        note,
        from: from,
        to: to,
        identity: identity,
        folder: true,
      );
      await movePathNoReplace(from, to);
    } on NativeNameCollision {
      await _notes.discard(note);
      return const FolderNameTaken();
    } on Object catch (error) {
      log.e('move the folder $from', error);
      await _notes.discard(note);
      return FolderMoveFailed(failureDetail(error));
    }
    await _adoptAll(documentNames, from, to);
    return const FolderMoved();
  }

  /// Hands each document's kept versions to the name it now has.
  Future<void> _adoptAll(List<String> names, String from, String to) async {
    for (final name in names) {
      final moved = p.join(to, name);
      await _backups.adopt(
        from: backupId(p.relative(p.join(from, name), from: documents.path)),
        to: backupId(p.relative(moved, from: documents.path)),
        documentPath: moved,
      );
    }
  }

  /// The relative PGN paths below [folder], or null when it cannot be
  /// listed — which is a reason not to move it at all.
  Future<List<String>?> _documentsIn(String folder) async {
    final names = <String>[];
    try {
      await for (final entry in directoryEntries(
        Directory(folder),
        recursive: true,
        followLinks: false,
      )) {
        if (entry is File && p.extension(entry.path) == '.pgn') {
          names.add(p.relative(entry.path, from: folder));
        }
      }
    } on FileSystemException catch (error) {
      log.e('list $folder before moving it', error);
      return null;
    }
    return names;
  }
}

/// The old app's chapter quarantine folder beside each chapter; both apps
/// delete into it, and `DeletedChapters` in `chapter_files.dart` lists what
/// is in it.
const recoveryFolder = '.cap-pgn-history';

const _unlistable = 'the folder could not be read';

const _unidentifiable = 'the folder could not be identified';

// Imports under a fault at every effect. Library.importText writes the new
// repertoire into an `.import-` staging folder the listing skips, creates
// its file there, then moves the folder into place (a journaled folder
// move); a staging folder a stopped import left is swept on the next
// listing. NativePgnFileImport.insideDocuments copies a file from outside
// Documents into `pgn_collections` under the first free name.
//
// Importing the same text twice makes a second repertoire beside the first
// by design; a retry after a lost acknowledgement is the same import, and
// making a second copy for it is not. See fault_matrix.dart for the
// families.
@TestOn('linux')
library;

import 'dart:io';

import 'package:chess_auto_prep/features/library/library.dart';
import 'package:chess_auto_prep/features/library/library_state.dart';
import 'package:chess_auto_prep/storage/pending_writes.dart';
import 'package:chess_auto_prep/storage/pgn_file_import.dart';
import 'package:chess_auto_prep/workspace/document_saver.dart';
import 'package:chess_auto_prep/workspace/document_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/faulty_disk/contracts.dart';
import '../../support/faulty_disk/fault_matrix.dart';
import '../../support/faulty_disk/known_findings.dart';
import '../../support/faulty_disk/scenario.dart';
import '../../support/faulty_disk/stores.dart';
import '../../support/fixtures.dart';
import '../../support/profile/profile.dart';
import '../../support/profile/standard_profile.dart';
import '../../support/viewer_fixture.dart';

/// The session's Library, wired as the app wires it, on a fixed clock so a
/// course's heading reads the same in every run.
Library _library(Stores s) => s.once('library', () {
  final pending = PendingWrites();
  final saver = DocumentSaver(s.documents, pendingWrites: pending);
  return Library(
    files: s.chapters,
    documents: s.documents,
    saver: saver,
    session: DocumentSession(s.documents, saver),
    picker: ScriptedPicker(),
    root: s.profile.repertoires,
    pendingWrites: pending,
    now: () => DateTime.utc(2026, 9, 29, 8),
  );
});

const _pasted =
    '[Event "Sicilian: Najdorf"]\n[Result "*"]\n\n'
    '1. e4 c5 2. Nf3 d6 3. d4 cxd4 4. Nxd4 Nf6 5. Nc3 a6 *\n\n'
    '[Event "Sicilian: Najdorf"]\n[Result "*"]\n\n'
    '1. e4 c5 2. Nf3 d6 3. d4 cxd4 4. Nxd4 Nf6 5. Nc3 a6 6. Be3 e5 *\n';

/// The text pasted as a new repertoire; the user's retry is the same paste.
Future<LibraryResult> _paste(Stores s) =>
    _library(s).importText(_pasted, name: 'Najdorf');

Verdict _imported(LibraryResult result) => switch (result) {
  LibraryAdded() => Verdict.committed,
  LibraryNameTaken() || LibraryNothingToImport() => Verdict.rejected,
  _ => Verdict.unknown,
};

Future<String> _repertoires(Stores s) => s.repertoires();

const _importRetry =
    'When moveFolder fails once the relocation record of an import\'s '
    'staging folder is installed, Library._placed '
    '(lib/features/library/library.dart) answers LibraryFailure, although '
    'the removeStaging cleanup that follows goes through the recovery gate '
    'and finishes the move first: the repertoire is in place, and importing '
    'again, the only retry the app offers, adds a second one beside it '
    '("Najdorf (2)").';

const _pasteKnown = {
  'transient/*/O8': _importRetry,
  'lostAck/*/O8': _importRetry,
  // The relocation findings of recoveryLedger that a full run
  // (CAP_FAULT_DEPTH=full) shows for the staging folder's move.
  'recoveryFault/*/read:Support/relocation-writes/*/O4': recordReadFailed,
  'recoveryMissing/*/read:Support/relocation-writes/*/O4': recordReadFailed,
  'recoveryMissing/*/stat:Support#*/O7': journalMissingSkipped,
  'recoveryMissing/*/stat:Support/relocation-writes*/O7': journalMissingSkipped,
};

const _pasteImport = StorageScenario<Stores, LibraryResult>(
  name: 'import pasted text',
  seed: seedStandardProfile,
  open: Stores.open,
  command: _paste,
  verdict: _imported,
  retry: _paste,
  firstRead: _repertoires,
  probes: standardProbes,
  known: _pasteKnown,
);

/// A course downloaded outside the profile: never written by the import.
String _download(Profile profile) =>
    p.join(p.dirname(profile.root), 'Downloads', 'Sicilian course.pgn');

Future<void> _seedDownload(Profile profile) async {
  await seedStandardProfile(profile);
  final file = File(_download(profile));
  await file.parent.create(recursive: true);
  await file.writeAsString(whiteChapter);
}

const _copied = 'pgn_collections/Sicilian course.pgn';

/// The downloaded course opened: copied into Documents to be opened there.
/// The user's retry opens the same file again.
Future<ImportResult> _open(Stores s) => NativePgnFileImport(
  documents: s.profile.documents,
  into: s.profile.document('pgn_collections'),
  recovery: s.documents.recovery,
).insideDocuments(_download(s.profile));

Verdict _opened(ImportResult result) => switch (result) {
  FileToOpen() => Verdict.committed,
  ImportFailed() => Verdict.unknown,
};

Future<String> _copy(Stores s) => s.openedAs(_copied);

const _collectionsUnflushed =
    'NativePgnFileImport._insideDocuments '
    '(lib/storage/pgn_file_import.dart) creates Documents/pgn_collections '
    'for the first copy and never flushes Documents, so after a power loss '
    'the folder, the copy and every later save of it can vanish with the '
    'folder entry.';

const _copyRetry =
    'When NativePgnFileImport._insideDocuments '
    '(lib/storage/pgn_file_import.dart) published the copy but its '
    'answer, or the flush of pgn_collections after it, failed, it answers '
    'ImportFailed, and opening the file again, the only retry, makes a second '
    'copy "Sicilian course (2).pgn" beside the first.';

const _openKnown = {
  'record/mkdir:Documents/pgn_collections#0/R2': _collectionsUnflushed,
  'crashMidway/publishNew:Documents/pgn_collections/*/O9': twoNames,
  'transient/syncDir:Documents/pgn_collections#0/O8': _copyRetry,
  'lostAck/*/O8': _copyRetry,
};

const _openOutside = StorageScenario<Stores, ImportResult>(
  name: 'open a file from outside Documents',
  seed: _seedDownload,
  open: Stores.open,
  command: _open,
  verdict: _opened,
  retry: _open,
  firstRead: _copy,
  probes: standardProbes,
  known: _openKnown,
);

void main() {
  faultMatrix(_pasteImport);
  faultMatrix(_openOutside);
}

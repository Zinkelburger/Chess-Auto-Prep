// A repertoire folder renamed with everything in it, under a fault at every
// effect: the folder inventory, the exclusive folder rename, the training
// rows and book selectors of every chapter in it, the kept versions, the
// recovery a crash leaves pending, faults inside that recovery, and another
// program's change before the restart. See fault_matrix.dart for the
// families.
@TestOn('linux')
library;

import 'dart:io';

import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/pgn/line_id_pins.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/faulty_disk/fault_matrix.dart';
import '../../support/faulty_disk/known_findings.dart';
import '../../support/faulty_disk/perturbations.dart';
import '../../support/faulty_disk/scenario.dart';
import '../../support/faulty_disk/stores.dart';
import '../../support/fixtures.dart';
import '../../support/profile/profile.dart';
import '../../support/profile/standard_profile.dart';

const _to = "repertoires/King's Indian";
const _movedMain = '$_to/Main.pgn';
const _movedCourse = '$_to/KID course.pgn';

/// KID, with its chapters, course, deleted chapter and their training and
/// books, renamed; a retry sends the same operation id.
Future<FolderMoveResult> _moveFolder(Stores s) => s.documents.moveFolder(
  s.profile.document('repertoires/KID'),
  s.profile.document(_to),
  operationId: 'fault-folder',
);

/// The training of two of the folder's chapters, where they are.
Future<String> _training(Stores s) async =>
    '${await s.trainingWhereItIs([kidMain, _movedMain])} | '
    '${await s.trainingWhereItIs([kidCourse, _movedCourse])}';

final _folderMove = StorageScenario<Stores, FolderMoveResult>(
  name: 'move a repertoire folder',
  seed: seedStandardProfile,
  open: Stores.open,
  command: _moveFolder,
  verdict: folderMoveVerdict,
  retry: _moveFolder,
  firstRead: _training,
  probes: standardProbes,
  perturbations: relocationPerturbations(
    chapters: [kidMain, _movedMain],
    lineId: trainedIdsOf(parseChapter(name: 'Main', text: blackChapter)).first!,
    folder: true,
  ),
  known: {
    // No case of a folder move leaves an orphan after a read under
    // Documents briefly misses (a full run shows none), unlike a chapter's.
    ...recoveryLedger('relocation-writes', books: true)
      ..remove('recoveryMissing/*/read:Documents/*/O6'),
  },
);

const _lone = 'repertoires/Group/Lone';

/// The standard profile with one more repertoire, alone in a group folder
/// that moving it out empties.
Future<void> _seedLoneFolder(Profile profile) async {
  await seedStandardProfile(profile);
  final chapter = File(profile.document('$_lone/Main.pgn'));
  await chapter.parent.create(recursive: true);
  await chapter.writeAsString(blackChapter);
}

Future<FolderMoveResult> _moveLone(Stores s) => s.documents.moveFolder(
  s.profile.document(_lone),
  s.profile.document('repertoires/Lone'),
  operationId: 'fault-folder-lone',
);

Future<String> _loneOpened(Stores s) => s.openedAs('repertoires/Lone/Main.pgn');

/// Every kill that leaves the move owed, with the group folder it emptied
/// then removed before the restart.
final _loneFolderMove = StorageScenario<Stores, FolderMoveResult>(
  name: 'move the last repertoire out of its group folder',
  seed: _seedLoneFolder,
  open: Stores.open,
  command: _moveLone,
  verdict: folderMoveVerdict,
  retry: _moveLone,
  firstRead: _loneOpened,
  perturbations: [emptiedFolderRemoved(_lone)],
);

void main() {
  faultMatrix(_folderMove);
  faultMatrix(_loneFolderMove, families: {Family.perturbed});
}

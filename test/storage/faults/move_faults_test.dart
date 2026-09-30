// A chapter moved to another repertoire, under a fault at every effect: the
// relocation journal over the file, its training rows, its book selectors
// and its kept versions, the recovery a crash leaves pending, faults inside
// that recovery, and another program's change before the restart. See
// fault_matrix.dart for the families.
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

const _to = 'repertoires/Benko/Main.pgn';

/// The main chapter, with its reviews, streak, history and kept versions,
/// moved into Benko; a retry sends the same revision and operation id.
Future<MoveResult> _move(Stores s) => s.documents.move(
  s.ref(kidMain),
  s.ref(_to),
  expected: s.once('main', () => revisionOf(s.textNow(kidMain))),
  operationId: 'fault-move',
);

/// The moved chapter's training, at whichever end of the move it is.
Future<String> _training(Stores s) => s.trainingWhereItIs([kidMain, _to]);

/// The first line of the main chapter, which has a review and history.
final _lineId = trainedIdsOf(
  parseChapter(name: 'Main', text: blackChapter),
).first!;

final _moveChapter = StorageScenario<Stores, MoveResult>(
  name: 'move a chapter',
  seed: seedStandardProfile,
  open: Stores.open,
  command: _move,
  verdict: moveVerdict,
  retry: _move,
  firstRead: _training,
  probes: standardProbes,
  perturbations: relocationPerturbations(
    chapters: [kidMain, _to],
    lineId: _lineId,
  ),
  known: {...recoveryLedger('relocation-writes', books: true)},
);

const _loneTo = 'repertoires/KID/Declined.pgn';

/// The standard profile with Benko's accepted chapter gone, so a move of
/// its declined one empties the folder.
Future<void> _seedLoneChapter(Profile profile) async {
  await seedStandardProfile(profile);
  await File(profile.document(benkoAccepted)).delete();
}

Future<MoveResult> _moveLone(Stores s) => s.documents.move(
  s.ref(benkoDeclined),
  s.ref(_loneTo),
  expected: s.once('declined', () => revisionOf(s.textNow(benkoDeclined))),
  operationId: 'fault-move-lone',
);

Future<String> _loneTraining(Stores s) =>
    s.trainingWhereItIs([benkoDeclined, _loneTo]);

/// Every kill that leaves the move owed, with the folder it emptied then
/// removed before the restart.
final _moveLoneChapter = StorageScenario<Stores, MoveResult>(
  name: 'move the last chapter out of its folder',
  seed: _seedLoneChapter,
  open: Stores.open,
  command: _moveLone,
  verdict: moveVerdict,
  retry: _moveLone,
  firstRead: _loneTraining,
  perturbations: [emptiedFolderRemoved(benkoDeclined)],
);

void main() {
  faultMatrix(_moveChapter);
  faultMatrix(_moveLoneChapter, families: {Family.perturbed});
}

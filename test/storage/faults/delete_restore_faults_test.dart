// A chapter deleted into its repertoire's recovery folder, and one deleted
// earlier restored out of it (a move back, as Library.restoreChapter makes
// it), each under a fault at every effect: the deleted bytes must always be
// somewhere, and a restore must bring the chapter's training and book
// selectors back with it. See fault_matrix.dart for the families.
@TestOn('linux')
library;

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
import '../../support/profile/standard_profile.dart';

/// A delete's id names the chapter it sets aside, so it has that shape.
const _deleteId = '1759132800000000-dead';

/// Where the delete sets the main chapter aside.
const _aside = 'repertoires/KID/.cap-pgn-history/$_deleteId-Main.pgn';

/// The main chapter, with its training, book selector and kept versions,
/// set aside; a retry sends the same revision and operation id.
Future<DeleteResult> _delete(Stores s) => s.documents.delete(
  s.ref(kidMain),
  expected: s.once('main', () => revisionOf(s.textNow(kidMain))),
  operationId: _deleteId,
);

Future<String> _deletedTraining(Stores s) =>
    s.trainingWhereItIs([kidMain, _aside]);

final _deleteChapter = StorageScenario<Stores, DeleteResult>(
  name: 'delete a chapter',
  seed: seedStandardProfile,
  open: Stores.open,
  command: _delete,
  verdict: deleteVerdict,
  retry: _delete,
  firstRead: _deletedTraining,
  probes: standardProbes,
  perturbations: relocationPerturbations(
    chapters: [kidMain, _aside],
    lineId: trainedIdsOf(parseChapter(name: 'Main', text: blackChapter)).first!,
  ),
  known: {...recoveryLedger('relocation-writes', books: true)},
);

/// The chapter the standard profile deleted while seeding, moved back to
/// where it was; a retry sends the same revision and operation id.
Future<MoveResult> _restore(Stores s) => s.documents.move(
  s.ref(kidDeletedAside),
  s.ref(kidDeleted),
  expected: s.once('old', () => revisionOf(s.textNow(kidDeletedAside))),
  operationId: 'fault-restore',
);

Future<String> _restoredTraining(Stores s) =>
    s.trainingWhereItIs([kidDeletedAside, kidDeleted]);

final _restoreChapter = StorageScenario<Stores, MoveResult>(
  name: 'restore a deleted chapter',
  seed: seedStandardProfile,
  open: Stores.open,
  command: _restore,
  verdict: moveVerdict,
  retry: _restore,
  firstRead: _restoredTraining,
  probes: standardProbes,
  perturbations: relocationPerturbations(
    chapters: [kidDeletedAside, kidDeleted],
    lineId: trainedIdsOf(
      parseChapter(name: 'Old', text: kidDeletedText),
    ).first!,
  ),
  known: {...recoveryLedger('relocation-writes', books: true)},
);

void main() {
  faultMatrix(_deleteChapter);
  faultMatrix(_restoreChapter);
}

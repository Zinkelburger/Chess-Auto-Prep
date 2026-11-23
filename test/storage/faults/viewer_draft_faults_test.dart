// The PGN Viewer's unsaved edits kept under a fault at every effect: a
// newer checkpoint of Benko Accepted written over the one kept before
// (`ViewerDraftFiles.keep`). The checkpoint is the only copy of those edits
// until the user saves, so a fault leaves the older checkpoint or the newer
// one, whole. A keep that throws is retried by the draft keeper with the
// same edits. See fault_matrix.dart for the families.
@TestOn('linux')
// Every case runs a fault matrix of isolates: four times the default
// 30 s, for a busy CI runner.
@Timeout.factor(4)
library;

import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/viewer_drafts.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/faulty_disk/contracts.dart';
import '../../support/faulty_disk/fault_matrix.dart';
import '../../support/faulty_disk/record_stores.dart';
import '../../support/faulty_disk/scenario.dart';
import '../../support/profile/standard_profile.dart';

/// The newer checkpoint: more edits to the same game.
Future<bool> _keep(RecordStores s) async {
  try {
    await s.drafts.keep(
      ViewerDraft(
        path: s.profile.document(benkoAccepted),
        game: 0,
        revision: const Revision(seededDraftRevision),
        text:
            '[Event "Draft"]\n[Result "*"]\n\n'
            '1. d4 Nf6 2. c4 c5 3. d5 b5 4. cxb5 a6 { Edited } *\n',
      ),
      // The checkpoint kept before is this window's own, as the draft
      // keeper says of the one it last wrote: nothing of another's to keep.
      previous: seededDraft(s.profile),
    );
    return true;
  } on Exception {
    return false;
  }
}

Verdict _kept(bool kept) => kept ? Verdict.committed : Verdict.unknown;

Future<String> _draft(RecordStores s) => s.draftNow();

const _scenario = StorageScenario<RecordStores, bool>(
  name: 'keep unsaved edits',
  seed: seedRecordProfile,
  open: RecordStores.open,
  command: _keep,
  verdict: _kept,
  retry: _keep,
  firstRead: _draft,
  probes: recordProbes,
);

void main() => faultMatrix(_scenario);

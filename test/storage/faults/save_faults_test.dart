// A save of one game of a chapter that already has kept versions, under a
// fault at every effect it makes: the version it replaces kept first (the
// version file and index.json), then the staged copy renamed over the
// chapter. See fault_matrix.dart for the families.
@TestOn('linux')
library;

import 'package:chess_auto_prep/chess/pgn/games_written.dart';
import 'package:chess_auto_prep/storage/edit_scope.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/faulty_disk/fault_matrix.dart';
import '../../support/faulty_disk/scenario.dart';
import '../../support/faulty_disk/stores.dart';
import '../../support/profile/standard_profile.dart';

/// The main chapter's first comment expanded; the same text and revision
/// on a retry.
Future<SaveResult> _saveMain(Stores s) {
  final text = s.once('main', () => s.textNow(kidMain));
  return s.documents.save(
    s.ref(kidMain),
    text.replaceFirst('{The Sicilian [', '{The Sicilian, the main line ['),
    expected: revisionOf(text),
    scope: GamesEdited(GamesWritten(rewritten: const {0})),
  );
}

Future<String> _opened(Stores s) => s.openedAs(kidMain);

const _saveRetry =
    'When the native replace renames the staged chapter into place but '
    'reports an error, PgnFileStore.save (lib/storage/pgn_file_store.dart '
    '_replace) answers IoFailure, and a retry with the same text and expected '
    'revision answers Conflict although the file holds exactly that text. '
    'Only a failed directory flush after the rename is reported as saved.';

const _save = StorageScenario<Stores, SaveResult>(
  name: 'save a chapter',
  seed: seedStandardProfile,
  open: Stores.open,
  command: _saveMain,
  verdict: saveVerdict,
  retry: _saveMain,
  firstRead: _opened,
  probes: standardProbes,
  known: {
    'lostAck/publishReplace:Documents/repertoires/KID/.Main.pgn.v2-tmp'
            '->Documents/repertoires/KID/Main.pgn#0/O8':
        _saveRetry,
  },
);

void main() => faultMatrix(_save);

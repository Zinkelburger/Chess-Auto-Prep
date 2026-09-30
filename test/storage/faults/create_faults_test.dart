// A new chapter created in a repertoire of the standard profile, under a
// fault at every effect it makes: the smallest publish (stage, flush, link
// then unlink, flush the folder). See fault_matrix.dart for the families.
@TestOn('linux')
library;

import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/faulty_disk/fault_matrix.dart';
import '../../support/faulty_disk/known_findings.dart';
import '../../support/faulty_disk/scenario.dart';
import '../../support/faulty_disk/stores.dart';
import '../../support/fixtures.dart';
import '../../support/profile/standard_profile.dart';

const _chapter = 'repertoires/KID/Classical.pgn';

Future<CreateResult> _createChapter(Stores s) =>
    s.documents.create(s.ref(_chapter), whiteChapter);

Future<String> _opened(Stores s) => s.openedAs(_chapter);

const _publishNew =
    'publishNew:Documents/repertoires/KID/.Classical.pgn.v2-tmp'
    '->Documents/repertoires/KID/Classical.pgn#0';

const _createRetry =
    'When installNewFile publishes the chapter but reports an error, '
    'PgnFileStore.create (lib/storage/pgn_file_store.dart) answers '
    'IoFailure, and a retry of the same create answers Collision for the '
    'file it made itself.';

const _create = StorageScenario<Stores, CreateResult>(
  name: 'create a chapter',
  seed: seedStandardProfile,
  open: Stores.open,
  command: _createChapter,
  verdict: createVerdict,
  retry: _createChapter,
  firstRead: _opened,
  probes: standardProbes,
  known: {
    'crashMidway/$_publishNew/O5': twoNames,
    'crashMidway/$_publishNew/O9': twoNames,
    'lostAck/$_publishNew/O8': _createRetry,
  },
);

void main() => faultMatrix(_create);

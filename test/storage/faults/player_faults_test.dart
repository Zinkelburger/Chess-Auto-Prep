// The player directory written under a fault at every effect: a player's
// rating edited in people.json, a group renamed in its own file and a group
// removed into `.removed` (`PlayerFiles`, each file replaced or moved whole
// under the folder lock). After any
// fault each file holds the old rows or the new ones, every other row and
// unknown field as it was, and the other records read as they did. A save
// that throws is retried with the same edit, which the store takes as done
// when the row already holds it. See fault_matrix.dart for the families.
@TestOn('linux')
// Every case runs a fault matrix of isolates: four times the default
// 30 s, for a busy CI runner.
@Timeout.factor(4)
library;

import 'package:chess_auto_prep/chess/players/player.dart';
import 'package:chess_auto_prep/storage/player_files.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/faulty_disk/contracts.dart';
import '../../support/faulty_disk/fault_matrix.dart';
import '../../support/faulty_disk/record_stores.dart';
import '../../support/faulty_disk/scenario.dart';

/// What a save answered: done, refused, or failed and to be retried.
typedef _Answer = Verdict;

Future<_Answer> _answer(Future<void> Function() save) async {
  try {
    await save();
    return Verdict.committed;
  } on PlayerConflict {
    return Verdict.rejected;
  } on Exception {
    return Verdict.unknown;
  }
}

/// When the edits below were made; an edit stamps the time, and a retry
/// sends the same row.
const _editedAt = '2026-09-29T08:00:00.000';

/// Ann's new rating; Bob and Ann's unknown field stay as they are.
Future<_Answer> _rate(RecordStores s) {
  final ann = seededPlayers.first;
  final edited = Player({
    ...ann.fields,
    'rating': 2055,
    'updated_at': _editedAt,
  });
  return _answer(() => s.players.savePlayer(edited, expected: ann));
}

/// The club's group under its new name.
Future<_Answer> _rename(RecordStores s) {
  final edited = PlayerGroup({
    ...seededGroup.fields,
    'name': 'Club championship 2026',
    'updated_at': _editedAt,
  });
  return _answer(() => s.players.saveGroup(edited, expected: seededGroup));
}

/// The club's group removed: moved into `.removed`, kept.
Future<_Answer> _remove(RecordStores s) =>
    _answer(() => s.players.removeGroup(seededGroup));

Verdict _verdict(_Answer answer) => answer;

Future<String> _players(RecordStores s) => s.playersNow();

const _rating = StorageScenario<RecordStores, _Answer>(
  name: 'edit a player',
  seed: seedRecordProfile,
  open: RecordStores.open,
  command: _rate,
  verdict: _verdict,
  retry: _rate,
  firstRead: _players,
  probes: recordProbes,
);

const _group = StorageScenario<RecordStores, _Answer>(
  name: 'rename a group',
  seed: seedRecordProfile,
  open: RecordStores.open,
  command: _rename,
  verdict: _verdict,
  retry: _rename,
  firstRead: _players,
  probes: recordProbes,
);

const _removal = StorageScenario<RecordStores, _Answer>(
  name: 'remove a group',
  seed: seedRecordProfile,
  open: RecordStores.open,
  command: _remove,
  verdict: _verdict,
  retry: _remove,
  firstRead: _players,
  probes: recordProbes,
);

void main() {
  faultMatrix(_rating);
  faultMatrix(_group);
  faultMatrix(_removal);
}

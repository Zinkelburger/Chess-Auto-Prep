// A course section renamed together with the book selector that names it,
// under a fault at every effect: the compound journal over the course and
// books.json, the recovery it leaves pending after a crash, and another
// program's change before the restart. See fault_matrix.dart for the
// families.
@TestOn('linux')
// Every case runs a fault matrix of isolates: four times the default
// 30 s, for a busy CI runner.
@Timeout.factor(4)
library;

import 'dart:io';

import 'package:chess_auto_prep/chess/pgn/games_written.dart';
import 'package:chess_auto_prep/storage/edit_scope.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/reference_change.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/faulty_disk/fault_matrix.dart';
import '../../support/faulty_disk/fault_plan.dart';
import '../../support/faulty_disk/faulty_disk.dart';
import '../../support/faulty_disk/io_trace.dart';
import '../../support/faulty_disk/known_findings.dart';
import '../../support/faulty_disk/perturbations.dart';
import '../../support/faulty_disk/scenario.dart';
import '../../support/faulty_disk/stores.dart';
import '../../support/profile/profile_snapshot.dart';
import '../../support/profile/profile_workspace.dart';
import '../../support/profile/standard_profile.dart';

const _from = 'Mar del Plata';
const _to = 'Classical';

/// The course's first section renamed, which rewrites its first two games;
/// a retry sends the same text, revision and operation id.
Future<SaveResult> _renameSection(Stores s) =>
    _renamed(s, 'rename', from: _from, to: _to);

Future<SaveResult> _renamed(
  Stores s,
  String name, {
  required String from,
  required String to,
}) {
  final ref = s.ref(kidCourse);
  final (text, scope) = s.once(
    name,
    () => (
      s.textNow(kidCourse),
      GamesEdited(
        GamesWritten(rewritten: const {0, 1}),
        references: ReferenceChanges([
          SectionRename(path: ref.path, from: from, to: to),
        ]),
      ),
    ),
  );
  return s.documents.save(
    ref,
    text.replaceAll('[ChapterName "$from"]', '[ChapterName "$to"]'),
    expected: revisionOf(text),
    scope: scope,
  );
}

/// The course's sections and every book's selectors: the two halves of the
/// rename, which must read back together.
Future<String> _sectionsAndSelectors(Stores s) async =>
    '${await s.sectionsOf(kidCourse)} | ${await s.bookSelectors()}';

final _rename = StorageScenario<Stores, SaveResult>(
  name: 'rename a course section',
  seed: seedStandardProfile,
  open: Stores.open,
  command: _renameSection,
  verdict: saveVerdict,
  retry: _renameSection,
  firstRead: _sectionsAndSelectors,
  probes: standardProbes,
  perturbations: [booksEditedMeanwhile, courseEditedElsewhere(kidCourse)],
  known: {...recoveryLedger('compound-writes')},
);

void main() {
  faultMatrix(_rename);

  // A filesystem that never flushes a folder (a VirtualBox shared folder,
  // some CIFS mounts) answers every flush under Documents with EINVAL.
  test('rename a course section where no folder can be flushed', () async {
    final workspace = await ProfileWorkspace.seeded(seedStandardProfile);
    addTearDown(workspace.dispose);
    final profile = await workspace.fresh();
    final run = await FaultyDisk(Directory(profile.root)).run(
      lastingFault(
        (op) =>
            op.kind == IoKind.syncDir &&
            (op.path == profile.documents ||
                p.isWithin(profile.documents, op.path)),
        IoError.einval,
      ),
      () async {
        final s = Stores.open(profile);
        final renamed = await _renameSection(s);
        final first = await _sectionsAndSelectors(s);
        final back = await _renamed(s, 'back', from: _to, to: _from);
        return [
          '${renamed.runtimeType}',
          first,
          '${back.runtimeType}',
          await _sectionsAndSelectors(s),
        ];
      },
    );
    final end = run.end;
    if (end is! Returned<List<String>>) fail('the run ended $end');
    final [renamed, first, back, last] = end.value;
    expect(renamed, 'Saved');
    expect(first, allOf(contains('#$_to'), isNot(contains('#$_from'))));
    expect(back, 'Saved');
    expect(last, allOf(contains('#$_from'), isNot(contains('#$_to'))));
    expect(ProfileSnapshot.of(profile).pending, isEmpty);
  });
}

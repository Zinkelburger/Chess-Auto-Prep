// A line moved from one chapter to another with its training, under a fault
// at every effect: the densest compound, the two PGNs and the four training
// files under one journal, the recovery a crash leaves pending, faults inside
// that recovery, and another program's change before the restart. See
// fault_matrix.dart for the families.
@TestOn('linux')
library;

import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/pgn/chapter_edit.dart';
import 'package:chess_auto_prep/chess/pgn/line_id_pins.dart';
import 'package:chess_auto_prep/chess/pgn/line_moves.dart';
import 'package:chess_auto_prep/storage/edit_scope.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/faulty_disk/fault_matrix.dart';
import '../../support/faulty_disk/known_findings.dart';
import '../../support/faulty_disk/perturbations.dart';
import '../../support/faulty_disk/scenario.dart';
import '../../support/faulty_disk/stores.dart';
import '../../support/fixtures.dart';
import '../../support/profile/standard_profile.dart';

/// The main chapter's second line, which has a streak record.
const _moving = 1;

/// The line taken out of the main chapter and added to the empty
/// sidelines chapter under the id it trains under, as LineTransfers plans
/// it; a retry sends the same edits and operation id.
Future<SaveResult> _moveLine(Stores s) {
  final (primary, secondary) = s.once('pair', () => _planned(s));
  return s.documents.savePair(primary, secondary, operationId: 'fault-pair');
}

(DocumentEdit, DocumentEdit) _planned(Stores s) {
  final sourceText = s.textNow(kidMain);
  final targetText = s.textNow(kidSidelines);
  final source = parseChapter(name: 'Main', text: sourceText);
  final target = parseChapter(name: 'Sidelines', text: targetText);
  final id = trainedIdsOf(source)[_moving]!;
  final line = withIdHeader(source.lines[_moving], id)!;
  final out = linesTakenOut(source, games: {_moving}) as ChapterEdited;
  final kept = withIdsPinned(source, out.chapter, out.games);
  final arriving = withFreeId(line, target.lines.length, idsInUse(target));
  final added = linesAddedTo(target, lines: [arriving]) as ChapterEdited;
  final placed = withIdsPinned(target, added.chapter, added.games);
  return (
    DocumentEdit(
      ref: s.ref(kidMain),
      text: writeChapter(kept.chapter),
      expected: revisionOf(sourceText),
      scope: GamesRearranged(kept.games),
      movedLines: {id: arriving.lineId!},
    ),
    DocumentEdit(
      ref: s.ref(kidSidelines),
      text: writeChapter(placed.chapter),
      expected: revisionOf(targetText),
      scope: GamesRearranged(placed.games),
    ),
  );
}

/// Both chapters' training: the moved line's streak is on one or the other.
Future<String> _training(Stores s) => s.trainedLines([kidMain, kidSidelines]);

/// The moved line's id, as the main chapter trains it before the move.
final _movedId = trainedIdsOf(
  parseChapter(name: 'Main', text: blackChapter),
)[_moving]!;

final _pair = StorageScenario<Stores, SaveResult>(
  name: 'move a line with its training',
  seed: seedStandardProfile,
  open: Stores.open,
  command: _moveLine,
  verdict: saveVerdict,
  retry: _moveLine,
  firstRead: _training,
  probes: standardProbes,
  perturbations: [
    // The training rows follow the PGNs: another program's change to them
    // is kept, and the moved line's rows, its answer too, are moved again.
    trainingAnswer(
      'answer for the moved line',
      chapters: [kidMain],
      lineId: _movedId,
      expect: Expected.finished,
      movedTo: kidSidelines,
    ),
    unrelatedAnswer(expect: Expected.finished),
    tornAttemptsLine(expect: Expected.finished),
    malformedReviewRow(expect: Expected.finished),
    // A PGN is the pair's: its source is put back and the record set aside.
    participantEditedElsewhere([kidSidelines], expect: Expected.putBack),
    // books.json is not the pair's: its record finishes over any change.
    booksEditedByOwner(chapters: [kidMain], expect: Expected.finished),
    badBookEntry(expect: Expected.finished),
    corruptJournal,
  ],
  known: {...recoveryLedger('compound-writes')},
);

void main() => faultMatrix(_pair);

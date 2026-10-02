// Training progress written under a fault at every effect: a line rated
// (its review, its move's streak and a history row: three files) and an
// answer logged (one file), each with its ProgressOperation as the retry
// token. Training answers are not journaled ("each training file is
// replaced atomically", docs/ARCHITECTURE_RENEWAL.md), so a kill between
// the rating's files may leave part of it by design: the crash families
// run on the answer, whose one file lands whole or not at all, and the
// rating runs the families in which the same session must finish it, once.
// See fault_matrix.dart for the families.
@TestOn('linux')
// Every case runs a fault matrix of isolates: four times the default
// 30 s, for a busy CI runner.
@Timeout.factor(4)
library;

import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/training/records.dart';
import 'package:chess_auto_prep/storage/training_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/faulty_disk/contracts.dart';
import '../../support/faulty_disk/fault_matrix.dart';
import '../../support/faulty_disk/scenario.dart';
import '../../support/faulty_disk/standard_commands.dart';
import '../../support/faulty_disk/stores.dart';
import '../../support/profile/standard_profile.dart';

/// A wrong answer in the main chapter; a retry logs the same one.
Future<ProgressWrite> _answer(Stores s) async {
  final operation = await s.once(
    'answer',
    () async => ProgressOperation(sources: (await admittedTraining(s)).sources),
  );
  return s.training.logAttempt(
    Attempt(
      key: mainLine(s, 0),
      ply: 3,
      fen: const Fen(
        'rnbqkb1r/pppppppp/5n2/8/3P4/8/PPP1PPPP/RNBQKBNR w KQkq - 1 2',
      ),
      played: 'Nc3',
      expected: 'c4',
      correct: false,
      phase: AttemptPhase.drilling,
      at: DateTime.utc(2026, 9, 29, 8),
    ),
    operation: operation,
  );
}

Verdict _progressVerdict(ProgressWrite result) => switch (result) {
  ProgressWritten() => Verdict.committed,
  ProgressFailed() => Verdict.unknown,
  ProgressConflict() || ProgressUnreadable() => Verdict.rejected,
};

Future<String> _ratedLine(Stores s) => ratedMainLine(s);

Future<String> _mainTraining(Stores s) => s.trainedLines([kidMain]);

const _rating = StorageScenario<Stores, ProgressWrite>(
  name: 'rate a line',
  seed: seedStandardProfile,
  open: Stores.open,
  command: rateMainLine,
  verdict: _progressVerdict,
  retry: rateMainLine,
  firstRead: _ratedLine,
  probes: standardProbes,
);

const _logged = StorageScenario<Stores, ProgressWrite>(
  name: 'log an answer',
  seed: seedStandardProfile,
  open: Stores.open,
  command: _answer,
  verdict: _progressVerdict,
  retry: _answer,
  firstRead: _mainTraining,
  probes: standardProbes,
);

void main() {
  faultMatrix(_rating, families: {Family.transient, Family.lostAck});
  faultMatrix(_logged);
}

// A trainer's progress owner (lib/features/trainer/progress.dart) as a
// drill drives it: a wrong answer logged, then the line rated, with an I/O
// error or a lost answer at each effect of those writes. Its PendingWrites
// must report a problem exactly while an accepted answer or rating is not
// in the training files, and the retry the trainer offers must land the
// rating once, never a second history row. See owner_faults.dart.
@TestOn('linux')
library;

import 'dart:io';

import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/training/records.dart';
import 'package:chess_auto_prep/chess/training/schedule.dart';
import 'package:chess_auto_prep/chess/training/training_line.dart';
import 'package:chess_auto_prep/features/trainer/progress.dart';
import 'package:chess_auto_prep/storage/pending_writes.dart';
import 'package:chess_auto_prep/storage/training_rows.dart';
import 'package:chess_auto_prep/storage/training_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/faulty_disk/owner_faults.dart';
import '../../support/faulty_disk/stores.dart';
import '../../support/fixtures.dart';
import '../../support/profile/profile.dart';
import '../../support/profile/standard_profile.dart';

/// KID's main chapter's lines, keyed where the standard profile has them.
List<TrainingLine> _lines(Profile profile) => trainingLines(
  parseChapter(name: 'Main', text: blackChapter),
  source: profile.document(kidMain),
);

/// A trainer's session: the store, and the progress it loaded.
final class _Trainer {
  _Trainer(this.stores);

  final Stores stores;
  final pending = PendingWrites();
  late final TrainingProgress progress;
  late final TrainingLine line = _lines(stores.profile).first;
}

_Trainer _open(Profile profile) => _Trainer(Stores.open(profile));

/// The scope loaded, as the trainer loads it before the first question.
Future<void> _load(_Trainer s) async {
  final path = s.stores.profile.document(kidMain);
  s.progress = TrainingProgress(
    files: s.stores.training,
    loaded: await s.stores.training.read({path}) as ProgressLoaded,
    time: (now: () => DateTime.utc(2026, 9, 29, 8), jitter: () => 0),
    pendingWrites: s.pending,
  );
}

/// Black's second move answered wrong, then the line rated hard: what the
/// trainer shows afterwards.
Future<String> _drill(_Trainer s) async {
  final answered = await s.progress.answered(s.line, (
    ply: 3,
    fen: const Fen(
      'rnbqkb1r/pppppppp/5n2/8/2PP4/8/PP2PPPP/RNBQKBNR b KQkq - 0 2',
    ),
    played: 'e6',
    expected: 'g6',
    correct: false,
    phase: AttemptPhase.drilling,
  ));
  final rated = await s.progress.finished(s.line, Rating.hard, clean: false);
  return '${answered.runtimeType}, ${rated.runtimeType}';
}

Future<void> _retry(_Trainer s) => s.progress.retry(s.line);

PendingWrites _pending(_Trainer s) => s.pending;

/// The line's rating and its move's streak, how many wrong answers the
/// chapter has, and how many history rows this rating wrote.
Future<String> _landed(Profile profile) async {
  final path = profile.document(kidMain);
  final key = _lines(profile).first.key;
  final store = TrainingStore(
    Directory(profile.documents),
    support: Directory(profile.support),
  );
  final read = await store.read({path});
  if (read is! ProgressLoaded) return 'unread: $read';
  final history = await File(profile.training(historyFile)).readAsLines();
  final rows = history.where(
    (row) => row.contains(key.id) && row.contains('2026-09-29T08:00'),
  );
  return 'rated ${read.reviews[key]?.lastRating}; '
      'streak ${read.streaks[(line: key, ply: 3)]?.streak}; '
      '${read.mistakes.length} mistakes; ${rows.length} history rows';
}

final _drilled = OwnerSequence<_Trainer>(
  name: 'answer and rate a line',
  seed: seedStandardProfile,
  open: _open,
  prepare: _load,
  run: _drill,
  pending: _pending,
  retry: _retry,
  landed: _landed,
);

void main() => ownerFaults(_drilled);

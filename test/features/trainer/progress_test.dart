import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/training/drill.dart';
import 'package:chess_auto_prep/chess/training/records.dart';
import 'package:chess_auto_prep/chess/training/schedule.dart';
import 'package:chess_auto_prep/chess/training/training_line.dart';
import 'package:chess_auto_prep/features/trainer/progress.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/pending_writes.dart';
import 'package:chess_auto_prep/storage/training_progress.dart';
import 'package:chess_auto_prep/storage/training_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_progress.dart';

const _chapter = '''
// Color: White

[Event "Ruy"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 *

[Event "Italian"]

1. e4 e5 2. Nf3 Nc6 3. Bc4 *
''';

const _source = '/repertoires/KID/Main.pgn';
final _now = DateTime.utc(2026, 9, 22, 12);

void main() {
  late _Recording files;
  late List<TrainingLine> lines;
  late PendingWrites pending;

  setUp(() {
    files = _Recording();
    pending = PendingWrites();
    lines = trainingLines(
      parseChapter(name: 'Main', text: _chapter),
      source: _source,
    );
  });

  Future<TrainingProgress> progressOf({
    Map<String, Revision> sources = const {},
  }) async {
    final read = await files.read({_source}) as ProgressLoaded;
    final progress = TrainingProgress(
      files: files,
      loaded: ProgressLoaded(
        reviews: read.reviews,
        streaks: read.streaks,
        mistakes: read.mistakes,
        sources: sources,
      ),
      time: (now: () => _now, jitter: () => 0),
      pendingWrites: pending,
    );
    addTearDown(progress.dispose);
    return progress;
  }

  DrillAnswer answer(int ply, {AttemptPhase phase = AttemptPhase.drilling}) {
    final san = lines.first.moves[ply].san;
    return (
      ply: ply,
      fen: Fen.initial,
      played: san,
      expected: san,
      correct: true,
      phase: phase,
    );
  }

  group('a save of the open chapter', () {
    const read = Revision('aaaa', nativeIdentity: 'inode-1');
    const saved = Revision('bbbb', nativeIdentity: 'inode-1');

    test('moves the version later writes name on', () async {
      final progress = await progressOf(sources: {_source: read});
      expect(progress.documentSaved(_source, read, saved), isTrue);
      expect(
        progress.documentSaved(_source, read, const Revision('cccc')),
        isFalse,
        reason: 'the rows now stand against the saved version',
      );
      expect(progress.documentSaved(_source, saved, read), isTrue);
    });

    test('from a version the rows were not read against means the chapter '
        'changed some other way', () async {
      final progress = await progressOf(sources: {_source: read});
      expect(progress.documentSaved(_source, saved, read), isFalse);
      expect(
        progress.documentSaved(
          _source,
          const Revision('aaaa', nativeIdentity: 'inode-2'),
          saved,
        ),
        isFalse,
        reason: 'the same text in another file',
      );
    });

    test('of a chapter outside the scope changes nothing', () async {
      final progress = await progressOf(sources: {_source: read});
      expect(progress.documentSaved('/elsewhere.pgn', saved, read), isTrue);
    });
  });

  test(
    'a move answered while it is being shown counts toward no streak',
    () async {
      final progress = await progressOf();
      await progress.answered(
        lines.first,
        answer(0, phase: AttemptPhase.learning),
      );
      await progress.answered(lines.first, answer(2));
      await progress.finished(lines.first, Rating.good, clean: true);

      final streaks = files.streakWrites.single;
      expect([for (final change in streaks) change.after.ply], [2]);
    },
  );

  test('a rating rewrites only the streaks it changed, each naming what the '
      'file held', () async {
    final ruy = lines.first.key;
    const loaded = 2;
    files.inner.streaks[(line: ruy, ply: 0)] = MoveStreak(
      key: ruy,
      ply: 0,
      streak: loaded,
      learned: false,
    );
    files.inner.streaks[(line: ruy, ply: 4)] = MoveStreak(
      key: ruy,
      ply: 4,
      streak: 1,
      learned: false,
    );
    // Another line's streak at the same ply is not this one's.
    files.inner.streaks[(line: lines.last.key, ply: 0)] = MoveStreak(
      key: lines.last.key,
      ply: 0,
      streak: 5,
      learned: true,
    );
    final progress = await progressOf();
    await progress.answered(lines.first, answer(0));
    await progress.finished(lines.first, Rating.good, clean: true);

    final change = files.streakWrites.single.single;
    expect(change.before?.streak, loaded);
    expect(change.after.streak, loaded + 1);
    expect(change.after.ply, 0);
  });

  group('an exclusion that failed', () {
    test('holds up the line\'s rating while it still fails', () async {
      final progress = await progressOf();
      files.inner.nextWrite = const ProgressFailed('disk full');
      expect(
        await progress.setExcluded(lines.first, excluded: true),
        isA<ProgressFailed>(),
      );
      files.inner.nextWrite = const ProgressFailed('disk full');
      expect(
        await progress.finished(lines.first, Rating.good, clean: true),
        isA<ProgressFailed>(),
      );
      expect(files.inner.reviews, isEmpty, reason: 'nothing written yet');
    });

    test('refused for good by one unreadable row does not hold the rating, '
        'and is still said', () async {
      final progress = await progressOf();
      files.inner.nextWrite = const ProgressFailed('disk full');
      await progress.setExcluded(lines.first, excluded: true);
      files.inner.nextWrite = const ProgressUnreadable(
        'repertoire_reviews.csv',
        3,
        wholeFile: false,
      );
      expect(
        await progress.finished(lines.first, Rating.good, clean: true),
        isA<ProgressWritten>(),
      );
      final review = files.inner.reviews[lines.first.key]!;
      expect((review.lastRating, review.excluded), ('good', false));
      expect(await pending.settle(), contains('A line could not be excluded.'));
    });
  });
}

/// [ScriptedProgress] that also keeps the streak changes each write asked
/// for, `before` and all.
final class _Recording implements ProgressFiles {
  final inner = ScriptedProgress();
  final streakWrites = <List<Change<MoveStreak>>>[];

  @override
  Future<ProgressAdmission> enqueueWrite({
    List<Change<Review>> reviews = const [],
    List<Change<MoveStreak>> streaks = const [],
    List<HistoryRow> history = const [],
    required ProgressOperation operation,
  }) => inner.enqueueWrite(
    reviews: reviews,
    streaks: streaks,
    history: history,
    operation: operation,
  );

  @override
  Future<ProgressAdmission> enqueueAttempt(
    Attempt attempt, {
    required ProgressOperation operation,
  }) => inner.enqueueAttempt(attempt, operation: operation);

  @override
  Future<ProgressWrite> commit(ProgressOperation operation) =>
      inner.commit(operation);

  @override
  Future<ProgressRead> read(
    Set<String> sources, {
    Map<String, Revision>? observed,
  }) => inner.read(sources, observed: observed);

  @override
  Future<ProgressWrite> write({
    List<Change<Review>> reviews = const [],
    List<Change<MoveStreak>> streaks = const [],
    List<HistoryRow> history = const [],
    ProgressOperation? operation,
  }) {
    if (streaks.isNotEmpty) streakWrites.add(streaks);
    return inner.write(
      reviews: reviews,
      streaks: streaks,
      history: history,
      operation: operation,
    );
  }

  @override
  Future<ProgressWrite> logAttempt(
    Attempt attempt, {
    ProgressOperation? operation,
  }) => inner.logAttempt(attempt, operation: operation);
}

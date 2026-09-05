import 'package:chess_auto_prep/models/repertoire_line.dart';
import 'package:chess_auto_prep/models/repertoire_move_progress.dart';
import 'package:chess_auto_prep/models/repertoire_review_entry.dart';
import 'package:chess_auto_prep/models/repertoire_review_history_entry.dart';
import 'package:chess_auto_prep/models/training_settings.dart';
import 'package:chess_auto_prep/services/repertoire_review_service.dart';
import 'package:chess_auto_prep/services/repertoire_service.dart';
import 'package:chess_auto_prep/services/training/review_progress_store.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

/// [ReviewProgressStore] holds the persisted half of training progress,
/// extracted from TrainingSessionController. The pure scheduling logic
/// (applyRating) stays real here; only the file writes are faked.

class _FakeRepertoireService extends RepertoireService {
  final headerUpdates = <String>[];

  /// Which file each header write landed in — a batch queued before a source
  /// switch has to be written back to the file it came from.
  final headerPaths = <String>[];

  @override
  Future<bool> updateLineReviewHeaders(
    String filePath,
    String lineId, {
    required DateTime? lastReview,
    required double difficulty,
    required double intervalDays,
    required DateTime? dueDate,
    required int passCount,
    required int failCount,
  }) async {
    headerUpdates.add(lineId);
    return true;
  }

  @override
  Future<bool> updateManyLineReviewHeaders(
    String filePath,
    Map<String, RepertoireReviewEntry> entriesByLineId,
  ) async {
    headerUpdates.addAll(entriesByLineId.keys);
    headerPaths.add(filePath);
    return true;
  }
}

class _FakeReviewService extends RepertoireReviewService {
  List<RepertoireReviewEntry> saved = [];
  String? savedRepertoireId;
  List<RepertoireMoveProgress> savedProgress = [];
  final history = <RepertoireReviewHistoryEntry>[];

  @override
  Future<void> saveAll(
    List<RepertoireReviewEntry> entries, {
    String? repertoireId,
  }) async {
    saved = List.of(entries);
    savedRepertoireId = repertoireId;
  }

  @override
  Future<void> saveMoveProgress(
    List<RepertoireMoveProgress> entries, {
    String? repertoireId,
  }) async {
    savedProgress = List.of(entries);
  }

  @override
  Future<void> appendHistory(List<RepertoireReviewHistoryEntry> entries) async {
    history.addAll(entries);
  }
}

RepertoireLine line(String id) => RepertoireLine(
  id: id,
  name: 'Line $id',
  moves: const ['e4', 'e5'],
  color: 'white',
  startPosition: Chess.initial,
  fullPgn: '',
);

void main() {
  late _FakeReviewService review;
  late _FakeRepertoireService repertoire;
  late TrainingSettings settings;
  late ReviewProgressStore store;
  late String repertoireId;

  setUp(() {
    review = _FakeReviewService();
    repertoire = _FakeRepertoireService();
    settings = TrainingSettings();
    repertoireId = '/rep.pgn';
    store = ReviewProgressStore(
      reviewService: review,
      repertoireService: repertoire,
      settings: () => settings,
      repertoireId: () => repertoireId,
    );
  });

  tearDown(() => store.dispose());

  group('recordRating', () {
    test('creates an entry for a line seen for the first time', () async {
      await store.recordRating(line('A'), ReviewRating.good, hadMistake: false);
      expect(store.byLine['A'], isNotNull);
      expect(store.byLine['A']!.lineName, 'Line A');
    });

    test('a clean pass increments passCount only', () async {
      await store.recordRating(line('A'), ReviewRating.good, hadMistake: false);
      expect(store.byLine['A']!.passCount, 1);
      expect(store.byLine['A']!.failCount, 0);
    });

    test('a line with a mistake increments failCount only', () async {
      await store.recordRating(line('A'), ReviewRating.again, hadMistake: true);
      expect(store.byLine['A']!.passCount, 0);
      expect(store.byLine['A']!.failCount, 1);
    });

    test('schedules the line — it is no longer new', () async {
      await store.recordRating(line('A'), ReviewRating.good, hadMistake: false);
      expect(store.byLine['A']!.isNew, isFalse);
    });

    test('writes a history row naming the rating', () async {
      await store.recordRating(line('A'), ReviewRating.hard, hadMistake: false);
      expect(review.history, hasLength(1));
      expect(review.history.single.rating, 'hard');
      expect(review.history.single.sessionType, 'trainer');
    });

    test('pushes the schedule into the PGN headers, batched', () async {
      await store.recordRating(line('A'), ReviewRating.good, hadMistake: false);
      await store.recordRating(line('B'), ReviewRating.good, hadMistake: false);
      expect(
        repertoire.headerUpdates,
        isEmpty,
        reason:
            'rewriting a multi-megabyte course between every line is a '
            'quarter-second stall the user feels',
      );

      await store.flushHeaders();
      expect(repertoire.headerUpdates, ['A', 'B']);

      // Nothing pending means nothing written.
      repertoire.headerUpdates.clear();
      await store.flushHeaders();
      expect(repertoire.headerUpdates, isEmpty);
    });

    test('a source switch flushes what the old file was owed', () async {
      await store.recordRating(line('A'), ReviewRating.good, hadMistake: false);
      final oldPath = repertoireId;
      repertoireId = '/other.pgn';
      store.adopt(byLine: {}, moveProgress: {}, otherRepertoires: []);
      await pumpEventQueue();

      expect(repertoire.headerUpdates, ['A']);
      expect(repertoire.headerPaths, [oldPath]);
    });

    test(
      'saves only the current repertoire, preserving other scopes in storage',
      () async {
        final other = RepertoireReviewEntry(
          repertoireId: '/other.pgn',
          lineId: 'Z',
          lineName: 'Other',
        );
        store.adopt(byLine: {}, moveProgress: {}, otherRepertoires: [other]);

        await store.recordRating(
          line('A'),
          ReviewRating.good,
          hadMistake: false,
        );
        expect(
          review.saved.map((e) => e.lineId),
          ['A'],
          reason: 'stale copies of other repertoires must not be written back',
        );
        expect(review.savedRepertoireId, repertoireId);
      },
    );
  });

  group('recordCompletion (linear mode)', () {
    test('bumps the tallies but leaves the line unscheduled', () async {
      await store.recordCompletion(line('A'), hadMistake: false);
      expect(store.byLine['A']!.passCount, 1);
      expect(
        store.byLine['A']!.isNew,
        isTrue,
        reason: 'linear completion must not create an SRS schedule',
      );
    });

    test('writes a history row with no rating', () async {
      await store.recordCompletion(line('A'), hadMistake: true);
      expect(review.history.single.rating, '');
      expect(review.history.single.sessionType, 'linear');
      expect(review.history.single.hadMistake, isTrue);
    });

    test('never touches the PGN headers', () async {
      await store.recordCompletion(line('A'), hadMistake: false);
      expect(repertoire.headerUpdates, isEmpty);
    });
  });

  group('applyLearnedSelection', () {
    final lines = [line('A'), line('B'), line('C')];

    test('seeds checked new lines as learned', () async {
      final changed = await store.applyLearnedSelection(lines, {'A', 'B'});
      expect(changed, 2);
      expect(store.byLine['A']!.isNew, isFalse);
      expect(store.byLine['B']!.isNew, isFalse);
      expect(store.byLine['C'], isNull);
    });

    test(
      'staggers seeded intervals so they do not all fall due together',
      () async {
        await store.applyLearnedSelection(lines, {'A', 'B', 'C'});
        final intervals = [
          'A',
          'B',
          'C',
        ].map((id) => store.byLine[id]!.intervalDays).toSet();
        expect(intervals.length, greaterThan(1));
      },
    );

    test('resets learned lines that were left unchecked', () async {
      await store.applyLearnedSelection(lines, {'A'});
      expect(store.byLine['A']!.isNew, isFalse);

      await store.applyLearnedSelection(lines, const <String>{});
      expect(store.byLine['A']!.isNew, isTrue);
    });

    test('keeps pass/fail history across a reset to new', () async {
      await store.recordRating(line('A'), ReviewRating.good, hadMistake: false);
      await store.recordRating(line('A'), ReviewRating.again, hadMistake: true);
      expect(store.byLine['A']!.passCount, 1);
      expect(store.byLine['A']!.failCount, 1);

      await store.applyLearnedSelection(lines, const <String>{});
      expect(store.byLine['A']!.isNew, isTrue);
      expect(store.byLine['A']!.passCount, 1, reason: 'tallies survive');
      expect(store.byLine['A']!.failCount, 1);
    });

    test(
      '`within` shields off-screen learned lines from being reset',
      () async {
        await store.applyLearnedSelection(lines, {'A', 'B'});
        expect(store.byLine['B']!.isNew, isFalse);

        // The user is filtered to chapter containing only A, and unchecks it.
        await store.applyLearnedSelection(
          lines,
          const <String>{},
          within: {'A'},
        );
        expect(store.byLine['A']!.isNew, isTrue);
        expect(
          store.byLine['B']!.isNew,
          isFalse,
          reason: 'B was never on screen, so it must not be reset',
        );
      },
    );

    test('returns 0 and writes nothing when the selection matches', () async {
      final changed = await store.applyLearnedSelection(
        lines,
        const <String>{},
      );
      expect(changed, 0);
      expect(review.history, isEmpty);
      expect(repertoire.headerUpdates, isEmpty);
    });

    test('repaints before writing to disk', () async {
      final order = <String>[];
      review.saved = [];
      await store.applyLearnedSelection(lines, {
        'A',
      }, onApplied: () => order.add('repaint'));
      order.add('written');
      expect(order, ['repaint', 'written']);
    });
  });

  group('per-move streaks', () {
    test('a correct answer builds the streak', () {
      final l = line('A');
      store.recordMove(l, 0, wasCorrect: true);
      store.recordMove(l, 0, wasCorrect: true);
      expect(store.moveProgress['A:0']!.correctStreak, 2);
    });

    test('the streak caps at the threshold once learned', () {
      settings.correctStreakThreshold = 2;
      final l = line('A');
      for (var i = 0; i < 5; i++) {
        store.recordMove(l, 0, wasCorrect: true);
      }
      expect(store.moveProgress['A:0']!.correctStreak, 2);
      expect(store.moveProgress['A:0']!.learned, isTrue);
    });

    test('a wrong answer resets the streak and unlearns the move', () {
      settings.correctStreakThreshold = 2;
      final l = line('A');
      store.recordMove(l, 0, wasCorrect: true);
      store.recordMove(l, 0, wasCorrect: true);
      expect(store.moveProgress['A:0']!.learned, isTrue);

      store.recordMove(l, 0, wasCorrect: false);
      expect(store.moveProgress['A:0']!.correctStreak, 0);
      expect(store.moveProgress['A:0']!.learned, isFalse);
    });

    test('moves are tracked independently within a line', () {
      final l = line('A');
      store.recordMove(l, 0, wasCorrect: true);
      store.recordMove(l, 2, wasCorrect: true);
      expect(store.moveProgress.keys, containsAll(['A:0', 'A:2']));
    });

    test('moveDifficulty is 0 for an untouched move and 1 once learned', () {
      settings.correctStreakThreshold = 2;
      final l = line('A');
      expect(store.moveDifficulty(l, 0), 0);
      store.recordMove(l, 0, wasCorrect: true);
      expect(store.moveDifficulty(l, 0), 0.5);
      store.recordMove(l, 0, wasCorrect: true);
      expect(store.moveDifficulty(l, 0), 1.0);
    });
  });

  test('supplier reads follow the owner’s current repertoire id', () async {
    var id = '/first.pgn';
    final s = ReviewProgressStore(
      reviewService: review,
      repertoireService: repertoire,
      settings: () => settings,
      repertoireId: () => id,
    );
    await s.recordRating(line('A'), ReviewRating.good, hadMistake: false);
    expect(s.byLine['A']!.repertoireId, '/first.pgn');

    id = '/second.pgn';
    await s.recordRating(line('B'), ReviewRating.good, hadMistake: false);
    expect(s.byLine['B']!.repertoireId, '/second.pgn');
  });
}

import 'dart:async';

import 'package:chess_auto_prep/models/repertoire_review_entry.dart';
import 'package:chess_auto_prep/models/repertoire_move_progress.dart';
import 'package:chess_auto_prep/features/training/models/training_settings.dart';
import 'package:chess_auto_prep/features/training/controllers/review_progress_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'training_fakes.dart';

class _PausedReviewService extends FakeReviewService {
  final saving = Completer<void>();
  final resume = Completer<void>();
  final saved = <(String?, List<RepertoireReviewEntry>)>[];
  final savedMoves = <(String?, List<RepertoireMoveProgress>)>[];
  @override
  Future<void> saveMoveProgress(
    List<RepertoireMoveProgress> entries, {
    String? repertoireId,
  }) async {
    savedMoves.add((repertoireId, List.of(entries)));
    await super.saveMoveProgress(entries, repertoireId: repertoireId);
  }

  @override
  Future<void> saveAll(
    List<RepertoireReviewEntry> entries, {
    String? repertoireId,
  }) async {
    if (!saving.isCompleted) saving.complete();
    await resume.future;
    saved.add((repertoireId, List.of(entries)));
    await super.saveAll(entries, repertoireId: repertoireId);
  }
}

void main() {
  test(
    'queued outcomes capture their own source and move snapshots before rebinding',
    () async {
      final reviews = _PausedReviewService();
      var source = '/first.pgn';
      final store = ReviewProgressStore(
        reviewService: reviews,
        headers: FakeRepertoireService().files,
        settings: () => TrainingSettings(),
        repertoireId: () => source,
      );
      addTearDown(store.dispose);
      final first = fakeLine('first', ['e4']);
      final saving = store.recordRating(
        first,
        ReviewRating.good,
        attempt: Object(),
        hadMistake: false,
      );
      await reviews.saving.future;
      source = '/queued.pgn';
      store.adopt(byLine: {}, moveProgress: {}, otherRepertoires: []);
      final queued = fakeLine('queued', ['d4']);
      store.recordMove(queued, 0, wasCorrect: false);
      final capturedMove = store.moveProgress.values.single;
      final attempt = Object();
      final queuedSave = store.recordRating(
        queued,
        ReviewRating.again,
        attempt: attempt,
        hadMistake: true,
      );
      // Concurrent retry of this same attempt joins its write, not a third history.
      final joined = store.recordRating(
        queued,
        ReviewRating.easy,
        attempt: attempt,
        hadMistake: false,
      );
      source = '/replacement.pgn';
      store.adopt(byLine: {}, moveProgress: {}, otherRepertoires: []);
      store.recordMove(fakeLine('replacement', ['c4']), 0, wasCorrect: true);
      reviews.resume.complete();
      await Future.wait([saving, queuedSave, joined]);
      await store.flushHeaders();
      expect(reviews.saved.map((write) => write.$1), [
        '/first.pgn',
        '/queued.pgn',
      ]);
      expect(reviews.saved.last.$2.single.lineId, 'queued');
      expect(reviews.saved.last.$2.single.lastRating, 'again');
      expect(reviews.savedMoves.last.$1, '/queued.pgn');
      expect(reviews.savedMoves.last.$2, [same(capturedMove)]);
      expect(reviews.history.map((entry) => entry.repertoireId), [
        '/first.pgn',
        '/queued.pgn',
      ]);
      expect(reviews.history.map((entry) => entry.rating), ['good', 'again']);
      expect(store.byLine, isEmpty);
      expect(store.moveProgress.values.single.repertoireId, '/replacement.pgn');
    },
  );

  for (final rated in [true, false]) {
    test(
      '${rated ? 'rating' : 'completion'} saves the original source snapshot',
      () async {
        final reviews = _PausedReviewService();
        var source = '/first.pgn';
        final store = ReviewProgressStore(
          reviewService: reviews,
          headers: FakeRepertoireService().files,
          settings: () => TrainingSettings(),
          repertoireId: () => source,
        );
        addTearDown(store.dispose);
        final first = fakeLine('first', ['e4', 'e5']);
        store.recordMove(first, 0, wasCorrect: true);
        final originalProgress = store.moveProgress.values.single;

        final saving = rated
            ? store.recordRating(
                first,
                ReviewRating.good,
                attempt: Object(),
                hadMistake: false,
              )
            : store.recordCompletion(
                first,
                attempt: Object(),
                hadMistake: false,
              );
        await reviews.saving.future;
        source = '/second.pgn';
        store.adopt(byLine: {}, moveProgress: {}, otherRepertoires: []);
        store.recordMove(
          fakeLine('second', ['d4', 'd5']),
          0,
          wasCorrect: false,
        );
        reviews.resume.complete();
        await saving;
        await store.flushHeaders();

        expect(reviews.entries.single.repertoireId, '/first.pgn');
        expect(reviews.progress, [same(originalProgress)]);
        expect(reviews.history.single.repertoireId, '/first.pgn');
        expect(store.moveProgress.values.single.repertoireId, '/second.pgn');
      },
    );
  }
}

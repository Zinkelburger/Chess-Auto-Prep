import 'dart:async';

import 'package:chess_auto_prep/models/repertoire_review_entry.dart';
import 'package:chess_auto_prep/models/training_settings.dart';
import 'package:chess_auto_prep/services/training/review_progress_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'training_fakes.dart';

class _PausedReviewService extends FakeReviewService {
  final saving = Completer<void>();
  final resume = Completer<void>();

  @override
  Future<void> saveAll(
    List<RepertoireReviewEntry> entries, {
    String? repertoireId,
  }) async {
    saving.complete();
    await resume.future;
    await super.saveAll(entries, repertoireId: repertoireId);
  }
}

void main() {
  for (final rated in [true, false]) {
    test(
      '${rated ? 'rating' : 'completion'} saves the original source snapshot',
      () async {
        final reviews = _PausedReviewService();
        var source = '/first.pgn';
        final store = ReviewProgressStore(
          reviewService: reviews,
          repertoireService: FakeRepertoireService(),
          settings: () => TrainingSettings(),
          repertoireId: () => source,
        );
        addTearDown(store.dispose);
        final first = fakeLine('first', ['e4', 'e5']);
        store.recordMove(first, 0, wasCorrect: true);
        final originalProgress = store.moveProgress.values.single;

        final saving = rated
            ? store.recordRating(first, ReviewRating.good, hadMistake: false)
            : store.recordCompletion(first, hadMistake: false);
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

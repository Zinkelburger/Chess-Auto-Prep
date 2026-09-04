/// [TrainingRun] on its own — what one sitting covers and what comes next.
///
/// These rules used to live inside `TrainingSessionController` and could only
/// be exercised by standing up a whole session with a repertoire file. They
/// are worth pinning on their own, because two of them are the fix for a real
/// defect and neither is obvious from the code:
///
///  * the scope is *fixed* when the run starts, so finishing a line cannot
///    pull a fresh one in behind it and a sitting over a long course ends;
///  * once inside that scope, the test is "not learned yet", not "still
///    matches the intent" — rating a new line Again moves it out of
///    *untrained*, and a strict intent match would drop the very line you
///    most need to see again.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/models/repertoire_line.dart';
import 'package:chess_auto_prep/models/repertoire_review_entry.dart';
import 'package:chess_auto_prep/models/training_settings.dart';
import 'package:chess_auto_prep/services/training/training_run.dart';

RepertoireLine _line(String id) => RepertoireLine(
  id: id,
  name: id,
  moves: const ['e4'],
  color: 'white',
  startPosition: Chess.initial,
  fullPgn: '',
);

/// No rating yet — [LineStatus.untrained].
RepertoireReviewEntry _untrained(String id) =>
    RepertoireReviewEntry(repertoireId: 'r', lineId: id, lineName: id);

/// Rated, and its due date has passed — [LineStatus.due].
RepertoireReviewEntry _due(String id) => RepertoireReviewEntry(
  repertoireId: 'r',
  lineId: id,
  lineName: id,
  lastRating: 'good',
  dueDateUtc: DateTime.utc(2020),
);

/// Rated, and not due for a long while — [LineStatus.learned].
RepertoireReviewEntry _learned(String id) => RepertoireReviewEntry(
  repertoireId: 'r',
  lineId: id,
  lineName: id,
  lastRating: 'good',
  dueDateUtc: DateTime.now().toUtc().add(const Duration(days: 30)),
);

void main() {
  late RepetitionMode mode;
  late TrainingSettings settings;
  late Map<String, RepertoireReviewEntry> reviews;

  TrainingRun makeRun() => TrainingRun(
    repetitionMode: () => mode,
    settings: () => settings,
    reviewMap: () => reviews,
  );

  setUp(() {
    mode = RepetitionMode.spaced;
    settings = TrainingSettings(newLinesPerSession: 2, reviewsPerSession: 2);
    reviews = {};
  });

  group('the sitting is fixed when it starts', () {
    test('a learn run takes the first N untrained lines and no more', () {
      final queue = [for (var i = 0; i < 5; i++) _line('l$i')];
      for (final l in queue) {
        reviews[l.id] = _untrained(l.id);
      }
      final run = makeRun()..begin(queue, TrainingIntent.learn);

      expect(run.isCapped, isTrue);
      expect(run.remaining(queue, TrainingIntent.learn), 2);
      expect(run.includes(queue[0], TrainingIntent.learn), isTrue);
      expect(run.includes(queue[2], TrainingIntent.learn), isFalse);
    });

    test('a line that becomes untrained later cannot join the run', () {
      // The defect this guards: a run rebuilt from the live queue on every
      // step never ends on a course with more lines than the cap.
      final queue = [_line('a'), _line('b'), _line('c')];
      reviews['a'] = _untrained('a');
      reviews['b'] = _untrained('b');
      reviews['c'] = _learned('c');
      final run = makeRun()..begin(queue, TrainingIntent.learn);

      reviews['c'] = _untrained('c');
      expect(run.includes(queue[2], TrainingIntent.learn), isFalse);
    });

    test('the cap being off leaves the run open to every matching line', () {
      settings = TrainingSettings(newLinesPerSession: 0);
      final queue = [for (var i = 0; i < 5; i++) _line('l$i')];
      for (final l in queue) {
        reviews[l.id] = _untrained(l.id);
      }
      final run = makeRun()..begin(queue, TrainingIntent.learn);

      expect(run.isCapped, isFalse);
      expect(run.remaining(queue, TrainingIntent.learn), 5);
    });
  });

  group('a line failed mid-run stays in it', () {
    test('rating a new line Again keeps it in the sitting', () {
      final queue = [_line('a'), _line('b')];
      reviews['a'] = _untrained('a');
      reviews['b'] = _untrained('b');
      final run = makeRun()..begin(queue, TrainingIntent.learn);

      // "Again" gives the line a rating, so it is no longer *untrained* —
      // it is due. A strict intent match would drop it from a Learn run.
      reviews['a'] = _due('a');
      expect(
        run.includes(queue[0], TrainingIntent.learn),
        isTrue,
        reason: 'the line you just failed is the one to come back to',
      );
    });

    test('but a line learned clean leaves the run', () {
      final queue = [_line('a'), _line('b')];
      reviews['a'] = _untrained('a');
      reviews['b'] = _untrained('b');
      final run = makeRun()..begin(queue, TrainingIntent.learn);

      reviews['a'] = _learned('a');
      expect(run.includes(queue[0], TrainingIntent.learn), isFalse);
      expect(run.remaining(queue, TrainingIntent.learn), 1);
    });
  });

  group('next', () {
    test('wraps around the queue to find the next line in the run', () {
      final queue = [_line('a'), _line('b'), _line('c')];
      reviews['a'] = _untrained('a');
      reviews['b'] = _learned('b');
      reviews['c'] = _untrained('c');
      settings = TrainingSettings(newLinesPerSession: 0);
      final run = makeRun()..begin(queue, TrainingIntent.learn);

      expect(run.next(queue, TrainingIntent.learn)?.id, 'a');
      expect(run.next(queue, TrainingIntent.learn, afterLineId: 'a')?.id, 'c');
      expect(
        run.next(queue, TrainingIntent.learn, afterLineId: 'c')?.id,
        'a',
        reason: 'wraps',
      );
    });

    test('is null when nothing in the queue is in the run', () {
      final queue = [_line('a')];
      reviews['a'] = _learned('a');
      final run = makeRun()..begin(queue, TrainingIntent.learn);
      expect(run.next(queue, TrainingIntent.learn), isNull);
    });

    test('is null on an empty queue rather than throwing', () {
      final run = makeRun()..begin(const [], TrainingIntent.review);
      expect(run.next(const [], TrainingIntent.review), isNull);
    });
  });

  group('linear mode', () {
    setUp(() => mode = RepetitionMode.linear);

    test('is never capped — every line once, in order, is the mode', () {
      final queue = [for (var i = 0; i < 5; i++) _line('l$i')];
      final run = makeRun()..begin(queue, TrainingIntent.learn);
      expect(run.isCapped, isFalse);
      expect(run.remaining(queue, TrainingIntent.learn), 5);
    });

    test('includes every line regardless of review status', () {
      final queue = [_line('a')];
      reviews['a'] = _learned('a');
      final run = makeRun()..begin(queue, TrainingIntent.review);
      expect(run.includes(queue[0], TrainingIntent.review), isTrue);
    });

    test('says the set is complete, not that you are caught up', () {
      final run = makeRun()..begin(const [], TrainingIntent.learn);
      expect(run.completeMessage(TrainingIntent.learn), 'Set complete!');
    });
  });

  group('completeMessage distinguishes why the run ended', () {
    test('hitting the sitting cap reads differently from running out', () {
      final queue = [for (var i = 0; i < 5; i++) _line('l$i')];
      for (final l in queue) {
        reviews[l.id] = _untrained(l.id);
      }
      final capped = makeRun()..begin(queue, TrainingIntent.learn);
      expect(capped.completeMessage(TrainingIntent.learn), contains('sitting'));

      final shortQueue = [_line('only')];
      reviews['only'] = _untrained('only');
      final ranOut = makeRun()..begin(shortQueue, TrainingIntent.learn);
      expect(
        ranOut.completeMessage(TrainingIntent.learn),
        'Nothing left to learn here.',
      );
    });

    test('review and learn get their own wording', () {
      final run = makeRun()..begin(const [], TrainingIntent.review);
      expect(run.completeMessage(TrainingIntent.review), 'All caught up!');
    });
  });

  test('clear drops the scope and the capped flag', () {
    final queue = [for (var i = 0; i < 5; i++) _line('l$i')];
    for (final l in queue) {
      reviews[l.id] = _untrained(l.id);
    }
    final run = makeRun()..begin(queue, TrainingIntent.learn);
    expect(run.isCapped, isTrue);

    run.clear();
    expect(run.isCapped, isFalse);
    expect(run.remaining(queue, TrainingIntent.learn), 5);
    expect(
      run.completeMessage(TrainingIntent.learn),
      'Nothing left to learn here.',
    );
  });
}

import 'dart:async';

import 'package:chess_auto_prep/features/training/controllers/review_progress_store.dart';
import 'package:chess_auto_prep/features/training/models/training_settings.dart';
import 'package:chess_auto_prep/features/training/repositories/training_review_repository.dart';
import 'package:chess_auto_prep/models/repertoire_review_entry.dart';
import 'package:chess_auto_prep/models/repertoire_review_history_entry.dart';
import 'package:flutter_test/flutter_test.dart';

import 'training_fakes.dart';

class _Reviews extends FakeReviewService {
  Completer<void>? gate;
  String? failStage;
  String? failSource;
  bool failAfterWrite = false;
  final writes = <(String?, List<RepertoireReviewEntry>)>[];
  final stages = <String>[];

  @override
  Future<void> saveAll(
    List<RepertoireReviewEntry> entries, {
    String? repertoireId,
  }) async {
    writes.add((repertoireId, List.of(entries)));
    stages.add('reviews:$repertoireId');
    await gate?.future;
    if (failStage == 'reviews' &&
        (failSource == null || failSource == repertoireId) &&
        !failAfterWrite) {
      throw StateError('reviews unavailable');
    }
    await super.saveAll(entries, repertoireId: repertoireId);
    if (failStage == 'reviews' &&
        (failSource == null || failSource == repertoireId)) {
      throw StateError('reviews acknowledgement lost');
    }
  }

  @override
  Future<void> appendHistory(List<RepertoireReviewHistoryEntry> entries) async {
    stages.add('history:${entries.first.repertoireId}');
    if (failStage == 'history' && !failAfterWrite) {
      throw StateError('history unavailable');
    }
    await super.appendHistory(entries);
    if (failStage == 'history') {
      throw StateError('history acknowledgement lost');
    }
  }
}

class _Headers implements TrainingHeaderRepository {
  bool fail = false;
  bool acknowledge = true;
  String? failPath;
  Completer<void>? gate;
  final writes = <(String, Map<String, RepertoireReviewEntry>)>[];
  @override
  Future<bool> updateManyLineReviewHeaders(
    String sourcePath,
    Map<String, RepertoireReviewEntry> entries,
  ) async {
    writes.add((sourcePath, Map.of(entries)));
    await gate?.future;
    if (fail || sourcePath == failPath) throw StateError('headers unavailable');
    return acknowledge;
  }
}

void main() {
  late _Reviews reviews;
  late _Headers headers;
  late ReviewProgressStore store;
  late String source;
  setUp(() {
    reviews = _Reviews();
    headers = _Headers();
    source = '/one.pgn';
    store = ReviewProgressStore(
      reviewService: reviews,
      headers: headers,
      settings: () => TrainingSettings(),
      repertoireId: () => source,
    );
  });
  tearDown(() => store.dispose());

  for (final stage in [
    'reviews',
    'history',
    'headers-throw',
    'headers-false',
  ]) {
    for (final afterWrite
        in stage == 'reviews' || stage == 'history' ? [false, true] : [false]) {
      test(
        '$stage ${afterWrite ? 'lost acknowledgement' : 'failure'} requires reload without replay',
        () async {
          final line = fakeLine('A', ['e4']);
          reviews.failStage = stage;
          reviews.failAfterWrite = afterWrite;
          headers.fail = stage == 'headers-throw';
          headers.acknowledge = stage != 'headers-false';
          await expectLater(
            store.applyLearnedSelection([line], {'A'}),
            throwsStateError,
          );
          expect(store.byLine, isEmpty, reason: 'no optimistic learned state');
          expect(store.requiresReload, isTrue);
          final writes = reviews.writes.length;
          final history = reviews.history.length;
          reviews.failStage = null;
          headers.fail = false;
          headers.acknowledge = true;
          await expectLater(
            store.applyLearnedSelection([line], {'A'}),
            throwsStateError,
          );
          await expectLater(
            store.recordRating(
              line,
              ReviewRating.good,
              attempt: Object(),
              hadMistake: false,
            ),
            throwsStateError,
          );
          await expectLater(
            store.recordCompletion(line, attempt: Object(), hadMistake: false),
            throwsStateError,
          );
          await expectLater(store.setExcluded(line, true), throwsStateError);
          expect(
            () => store.recordMove(line, 0, wasCorrect: true),
            throwsStateError,
          );
          expect(reviews.writes, hasLength(writes));
          expect(
            reviews.history,
            hasLength(history),
            reason: 'no history replay',
          );
          store.adopt(
            byLine: {for (final entry in reviews.entries) entry.lineId: entry},
            moveProgress: {},
            otherRepertoires: [],
          );
          expect(store.requiresReload, isFalse);
          expect(
            reviews.writes,
            hasLength(writes),
            reason: 'reload does not write the failed command',
          );
        },
      );
    }
  }

  test(
    'an in-flight failed old-source mirror does not poison new bulk',
    () async {
      final line = fakeLine('A', ['e4']);
      await store.recordRating(
        line,
        ReviewRating.good,
        attempt: Object(),
        hadMistake: false,
      );
      headers.failPath = '/one.pgn';
      headers.gate = Completer();
      final oldFlush = store.flushHeaders();
      source = '/two.pgn';
      store.adopt(byLine: {}, moveProgress: {}, otherRepertoires: []);
      final bulk = store.applyLearnedSelection([line], {'A'});
      await Future<void>.delayed(Duration.zero);
      expect(reviews.writes, hasLength(1));
      headers.gate!.complete();
      await oldFlush;
      expect(await bulk, 1);
      expect(store.requiresReload, isFalse);
      expect(store.byLine['A']!.repertoireId, '/two.pgn');
      expect(headers.writes.map((write) => write.$1), ['/one.pgn', '/two.pgn']);
    },
  );

  test(
    'bulk captures every source before awaits and publishes only after all acknowledgements',
    () async {
      source = '/course';
      final a = fakeLine('A', ['e4']).inSource('/course/a.pgn', 'One');
      final b = fakeLine('B', ['d4']).inSource('/course/b.pgn', 'Two');
      final lines = [a, b];
      final checked = {a.id, b.id};
      final scope = {a.id, b.id};
      reviews.gate = Completer<void>();
      final pending = store.applyLearnedSelection(
        lines,
        checked,
        within: scope,
      );
      await Future<void>.delayed(Duration.zero);
      expect(store.editBusy, isTrue);
      expect(store.byLine, isEmpty);
      lines.clear();
      checked.clear();
      scope.clear();
      source = '/replacement';
      await expectLater(
        store.applyLearnedSelection([a], {a.id}),
        throwsStateError,
      );
      await expectLater(store.setExcluded(a, true), throwsStateError);
      await expectLater(
        store.recordRating(
          a,
          ReviewRating.good,
          attempt: Object(),
          hadMistake: false,
        ),
        throwsStateError,
      );
      await expectLater(
        store.recordCompletion(a, attempt: Object(), hadMistake: false),
        throwsStateError,
      );
      expect(() => store.recordMove(a, 0, wasCorrect: true), throwsStateError);
      bool settled = false;
      final settlement = store.settleOutcomes().then((_) => settled = true);
      await Future<void>.delayed(Duration.zero);
      expect(settled, isFalse);
      reviews.gate!.complete();
      expect(await pending, 2);
      await settlement;
      expect(store.byLine.keys, [a.id, b.id]);
      expect(reviews.writes.map((write) => write.$1), [
        '/course/a.pgn',
        '/course/b.pgn',
      ]);
      expect(reviews.writes.map((write) => write.$2.single.lineId), ['A', 'B']);
      expect(headers.writes.map((write) => write.$1), [
        '/course/a.pgn',
        '/course/b.pgn',
      ]);
      expect(reviews.history.map((entry) => entry.repertoireId), [
        '/course/a.pgn',
        '/course/b.pgn',
      ]);
    },
  );

  test(
    'second source failure leaves original map and blocks all commands without replaying first source',
    () async {
      final a = fakeLine('A', ['e4']).inSource('/a.pgn', 'One');
      final b = fakeLine('B', ['d4']).inSource('/b.pgn', 'Two');
      reviews.failStage = 'reviews';
      reviews.failSource = '/b.pgn';
      await expectLater(
        store.applyLearnedSelection([a, b], {a.id, b.id}),
        throwsStateError,
      );
      expect(store.byLine, isEmpty);
      expect(reviews.entries.single.repertoireId, '/a.pgn');
      expect(reviews.history.single.repertoireId, '/a.pgn');
      expect(headers.writes.single.$1, '/a.pgn');
      await expectLater(
        store.applyLearnedSelection([a, b], {a.id, b.id}),
        throwsStateError,
      );
      expect(reviews.history, hasLength(1));
    },
  );

  for (final failure in [false, true]) {
    test(
      'old-source bulk ${failure ? 'failure' : 'success'} cannot publish into a new adoption',
      () async {
        final line = fakeLine('A', ['e4']);
        reviews.gate = Completer<void>();
        reviews.failStage = failure ? 'reviews' : null;
        final pending = store.applyLearnedSelection([line], {'A'});
        final checked = failure
            ? expectLater(pending, throwsStateError)
            : pending;
        await Future<void>.delayed(Duration.zero);
        final replacement = <String, RepertoireReviewEntry>{};
        store.adopt(
          byLine: replacement,
          moveProgress: {},
          otherRepertoires: [],
        );
        reviews.gate!.complete();
        await checked;
        expect(store.byLine, same(replacement));
        expect(replacement, isEmpty);
        expect(store.requiresReload, isFalse);
      },
    );
  }

  test(
    'bulk rejects pending and failed outcomes until they settle or are abandoned',
    () async {
      final line = fakeLine('A', ['e4']);
      reviews.gate = Completer<void>();
      reviews.failStage = 'history';
      final pending = store.recordRating(
        line,
        ReviewRating.good,
        attempt: Object(),
        hadMistake: false,
      );
      final failed = expectLater(pending, throwsStateError);
      await expectLater(
        store.applyLearnedSelection([line], {}),
        throwsStateError,
      );
      reviews.gate!.complete();
      await failed;
      await expectLater(
        store.applyLearnedSelection([line], {}),
        throwsStateError,
      );
      expect(
        store.requiresReload,
        isFalse,
        reason: 'admission rejection is not another failed write',
      );
    },
  );

  test(
    'exclusion uses the same settlement and rejects competing progress writes',
    () async {
      final line = fakeLine('A', ['e4']);
      reviews.gate = Completer<void>();
      final pending = store.setExcluded(line, true);
      await Future<void>.delayed(Duration.zero);
      expect(store.byLine, isEmpty);
      await expectLater(
        store.applyLearnedSelection([line], {'A'}),
        throwsStateError,
      );
      await expectLater(
        store.recordCompletion(line, attempt: Object(), hadMistake: false),
        throwsStateError,
      );
      bool settled = false;
      final barrier = store.settleOutcomes().then((_) => settled = true);
      await Future<void>.delayed(Duration.zero);
      expect(settled, isFalse);
      reviews.gate!.complete();
      await pending;
      await barrier;
      expect(store.byLine['A']?.excluded, isTrue);
    },
  );

  test(
    'failed exclusion blocks further edits until durable adoption',
    () async {
      reviews.failStage = 'reviews';
      final line = fakeLine('A', ['e4']);
      await expectLater(store.setExcluded(line, true), throwsStateError);
      expect(store.byLine, isEmpty);
      expect(store.requiresReload, isTrue);
      await expectLater(
        store.applyLearnedSelection([line], {'A'}),
        throwsStateError,
      );
    },
  );

  test(
    'unacknowledged earlier header mirror stops bulk before CSV or history',
    () async {
      final line = fakeLine('A', ['e4']);
      await store.recordRating(
        line,
        ReviewRating.good,
        attempt: Object(),
        hadMistake: false,
      );
      final writes = reviews.writes.length;
      headers.acknowledge = false;
      await expectLater(
        store.applyLearnedSelection([line], {}),
        throwsStateError,
      );
      expect(reviews.writes, hasLength(writes));
      expect(reviews.history, hasLength(1));
      expect(store.requiresReload, isTrue);
      headers.acknowledge = true;
      await store.flushHeaders();
      expect(headers.writes.last.$2['A']!.lastRating, 'good');
    },
  );

  test(
    'obsolete header error is suppressed even when the source path is reused',
    () async {
      final errors = <Object>[];
      store.onError = errors.add;
      final line = fakeLine('A', ['e4']);
      await store.recordRating(
        line,
        ReviewRating.good,
        attempt: Object(),
        hadMistake: false,
      );
      headers.gate = Completer<void>();
      headers.fail = true;
      final flushing = store.flushHeaders();
      store.adopt(byLine: {}, moveProgress: {}, otherRepertoires: []);
      headers.gate!.complete();
      await flushing;
      expect(errors, isEmpty);
    },
  );
  test(
    'header drain preserves a newer same-line entry queued during its await',
    () async {
      final line = fakeLine('A', ['e4']);
      await store.recordRating(
        line,
        ReviewRating.good,
        attempt: Object(),
        hadMistake: false,
      );
      headers.gate = Completer<void>();
      final first = store.byLine['A'];
      final flushing = store.flushHeaders();
      await store.recordRating(
        line,
        ReviewRating.again,
        attempt: Object(),
        hadMistake: true,
      );
      final second = store.byLine['A'];
      headers.gate!.complete();
      await flushing;
      expect(headers.writes, hasLength(2));
      expect(headers.writes.first.$2['A'], same(first));
      expect(headers.writes.last.$2['A'], same(second));
      await store.flushHeaders();
      expect(
        headers.writes,
        hasLength(2),
        reason: 'acknowledged entries drained',
      );
    },
  );
}

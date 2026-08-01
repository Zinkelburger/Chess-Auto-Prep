/// The store that lets one engine pass serve both outputs: the miner files each
/// game's mistake counts here, and the games list reads them.
library;

import 'package:chess_auto_prep/services/games_library/game_review_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const counts = ReviewCounts(inaccuracies: 2, mistakes: 1, blunders: 0);

  test('a recorded game reads back, and notifies the list', () async {
    SharedPreferences.setMockInitialValues({});
    final store = GameReviewStore.forTest();
    var notifications = 0;
    store.addListener(() => notifications++);

    await store.record('https://lichess.org/abc', counts);

    expect(store.countsFor('https://lichess.org/abc'), counts);
    expect(notifications, greaterThan(0));
  });

  test('a clean game is a result, not a missing one', () async {
    SharedPreferences.setMockInitialValues({});
    final store = GameReviewStore.forTest();

    await store.record(
      'g1',
      const ReviewCounts(inaccuracies: 0, mistakes: 0, blunders: 0),
    );

    // The distinction the whole store exists for: "reviewed, nothing wrong"
    // has to be tellable from "not reviewed yet".
    expect(store.countsFor('g1'), isNotNull);
    expect(store.countsFor('never-reviewed'), isNull);
  });

  test('re-recording the same verdict does not notify again', () async {
    SharedPreferences.setMockInitialValues({});
    final store = GameReviewStore.forTest();
    await store.record('g1', counts);

    var notifications = 0;
    store.addListener(() => notifications++);
    await store.record('g1', counts);

    expect(notifications, 0);
    expect(store.countsFor('g1'), counts);
  });

  test('a fresh review of the same game replaces the old verdict', () async {
    SharedPreferences.setMockInitialValues({});
    final store = GameReviewStore.forTest();
    await store.record('g1', counts);

    const deeper = ReviewCounts(inaccuracies: 1, mistakes: 1, blunders: 1);
    await store.record('g1', deeper);

    expect(store.countsFor('g1'), deeper);
    expect(store.length, 1);
  });

  test('an empty key is not a game', () async {
    SharedPreferences.setMockInitialValues({});
    final store = GameReviewStore.forTest();
    await store.record('', counts);
    expect(store.length, 0);
  });

  test('counts survive a restart', () async {
    SharedPreferences.setMockInitialValues({});
    final writer = GameReviewStore.forTest();
    await writer.record('g1', counts);

    final reader = GameReviewStore.forTest();
    await reader.ensureLoaded();

    expect(reader.countsFor('g1'), counts);
  });

  test('the oldest verdicts are evicted past the cap', () async {
    SharedPreferences.setMockInitialValues({});
    final store = GameReviewStore.forTest();

    for (var i = 0; i < GameReviewStore.maxEntries + 5; i++) {
      await store.record('g$i', counts);
    }

    expect(store.length, GameReviewStore.maxEntries);
    expect(store.countsFor('g0'), isNull, reason: 'oldest dropped');
    expect(
      store.countsFor('g${GameReviewStore.maxEntries + 4}'),
      counts,
      reason: 'newest kept',
    );
  });

  test('a corrupt store is a cache miss, not a crash', () async {
    SharedPreferences.setMockInitialValues({'game_review.counts': 'not json'});
    final store = GameReviewStore.forTest();

    await store.ensureLoaded();

    expect(store.length, 0);
    expect(store.countsFor('g1'), isNull);
  });
}

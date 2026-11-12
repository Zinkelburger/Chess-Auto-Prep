import 'package:chess_auto_prep/chess/training/training_options.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const set = TrainingOptions(
    learnLimit: 4,
    reviewLimit: 20,
    replyMillis: 1500,
    replayMistakes: false,
    rateReviews: true,
    repertoirePath: '/r/KID',
    reviewAll: true,
    pausedScopes: {'/r/KID/Main.pgn', '/r/Benko'},
  );

  test('a new sitting learns ten lines, reviews every due one and replays '
      'mistakes', () {
    const options = TrainingOptions.defaults;
    expect(
      (options.learnLimit, options.reviewLimit, options.replyMillis),
      (10, 0, 700),
    );
    expect(
      (options.replayMistakes, options.rateReviews, options.reviewAll),
      (true, false, false),
    );
    expect(options.repertoirePath, '');
    expect(options.pausedScopes, isEmpty);
  });

  test('every option survives a round trip', () {
    expect(TrainingOptions.fromJson(set.toJson()), set);
    expect(TrainingOptions.fromJson(set.toJson()).hashCode, set.hashCode);
  });

  test('anything unreadable reads as the default', () {
    expect(TrainingOptions.fromJson(null), TrainingOptions.defaults);
    expect(
      TrainingOptions.fromJson(const <String, Object?>{}),
      TrainingOptions.defaults,
    );
    expect(
      TrainingOptions.fromJson(const <String, Object?>{
        'learnLimit': '4',
        'reviewLimit': 2.5,
        'replyMillis': null,
        'replayMistakes': 'no',
        'rateReviews': 1,
        'repertoirePath': 7,
        'reviewAll': 'true',
        'pausedScopes': '/r/KID',
      }),
      TrainingOptions.defaults,
    );
  });

  test('numbers are held to their ranges, bounds included', () {
    TrainingOptions read(int learn, int review, int reply) =>
        TrainingOptions.fromJson(<String, Object?>{
          'learnLimit': learn,
          'reviewLimit': review,
          'replyMillis': reply,
        });
    final low = read(-1, -1, 199);
    expect((low.learnLimit, low.reviewLimit, low.replyMillis), (0, 0, 200));
    final high = read(1001, 1001, 2001);
    expect(
      (high.learnLimit, high.reviewLimit, high.replyMillis),
      (1000, 1000, 2000),
    );
    final edges = read(1000, 1000, 2000);
    expect(
      (edges.learnLimit, edges.reviewLimit, edges.replyMillis),
      (1000, 1000, 2000),
    );
    final bottom = read(0, 0, 200);
    expect(
      (bottom.learnLimit, bottom.reviewLimit, bottom.replyMillis),
      (0, 0, 200),
    );
  });

  test('paused scopes keep only their names', () {
    final options = TrainingOptions.fromJson(const <String, Object?>{
      'pausedScopes': ['/r/KID', 3, null, '/r/Benko'],
    });
    expect(options.pausedScopes, {'/r/KID', '/r/Benko'});
  });

  test('options are equal only when every one is', () {
    expect(set.copyWith(), set);
    expect(set.copyWith(pausedScopes: {'/r/Benko', '/r/KID/Main.pgn'}), set);
    final changed = {
      'learnLimit': set.copyWith(learnLimit: 5),
      'reviewLimit': set.copyWith(reviewLimit: 21),
      'replyMillis': set.copyWith(replyMillis: 1400),
      'replayMistakes': set.copyWith(replayMistakes: true),
      'rateReviews': set.copyWith(rateReviews: false),
      'repertoirePath': set.copyWith(repertoirePath: '/r/Benko'),
      'reviewAll': set.copyWith(reviewAll: false),
      'pausedScopes, one fewer': set.copyWith(pausedScopes: {'/r/Benko'}),
      'pausedScopes, one more': set.copyWith(
        pausedScopes: {...set.pausedScopes, '/r/Other'},
      ),
      'pausedScopes, another': set.copyWith(
        pausedScopes: {'/r/Benko', '/r/Other'},
      ),
    };
    for (final MapEntry(key: option, value: other) in changed.entries) {
      expect(other == set, isFalse, reason: option);
    }
  });
}

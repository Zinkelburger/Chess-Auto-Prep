import 'package:chess_auto_prep/chess/training/schedule.dart';
import 'package:chess_auto_prep/chess/training/sitting.dart';
import 'package:chess_auto_prep/features/trainer/trainer_words.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a span reads in the largest unit that still fits a button', () {
    const hour = 1 / 24;
    final cases = <double, String>{
      0: 'now',
      hour / 2: 'now',
      // 1.5 h rounds to 2h, and is past the hour that still reads "now".
      1.5 / 24: '2h',
      1 / 24.5: 'now',
      hour: '1h',
      0.5: '12h',
      0.99: '24h',
      1: '1d',
      1.5: '2d',
      13.4: '13d',
      14: '2w',
      14.5: '2w',
      35: '5w',
      59: '8w',
      60: '2mo',
      60.5: '2mo',
      120: '4mo',
    };
    for (final MapEntry(key: days, value: words) in cases.entries) {
      expect(spanWords(days), words, reason: '$days days');
    }
  });

  test('a rating button names the rating and the interval it schedules', () {
    const review = Review(
      key: (source: '/r/Main.pgn', id: 'a'),
      lineName: 'Main line',
      intervalDays: 10,
      lastRating: 'good',
    );
    expect(
      ratingLabel(Rating.good, review),
      'Good · ${spanWords(intervalFor(review, Rating.good))}',
    );
    expect(ratingLabel(Rating.good, review), 'Good · 4w');
  });

  test('a learned line says how long until it is due', () {
    final now = DateTime.utc(2026, 11, 20, 12);
    final review = Review(
      key: (source: '/r/Main.pgn', id: 'a'),
      lineName: 'Main line',
      due: now.add(const Duration(days: 3)),
    );
    expect(statusWord(LineStatus.learned, review, now), 'Learned · in 3d');
    expect(statusWord(LineStatus.learned, null, now), 'Learned · in a while');
  });
}

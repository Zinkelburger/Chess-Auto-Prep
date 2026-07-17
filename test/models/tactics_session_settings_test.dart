import 'package:chess_auto_prep/models/tactics_position.dart';
import 'package:chess_auto_prep/models/tactics_session_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// PGN-style `YYYY.MM.DD` for [d].
String _dateStr(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}.'
    '${d.month.toString().padLeft(2, '0')}.'
    '${d.day.toString().padLeft(2, '0')}';

/// A game date recent enough to pass the default 14-day recency window.
String get _recentDate => _dateStr(DateTime.now());

TacticsPosition _pos({
  required String fen,
  String mistakeType = '??',
  int rating = 0,
  int reviewCount = 0,
  String? gameDate,
}) {
  return TacticsPosition(
    fen: fen,
    gameWhite: 'A',
    gameBlack: 'B',
    gameResult: '1-0',
    gameDate: gameDate ?? _recentDate,
    gameId: fen,
    positionContext: 'Move 1 — White to play',
    userMove: 'd4',
    correctLine: const ['e4'],
    mistakeType: mistakeType,
    mistakeAnalysis: 'test',
    rating: rating,
    reviewCount: reviewCount,
  );
}

void main() {
  group('TacticsSessionSettings.accepts / countMatching', () {
    test(
      'default settings include blunders and mistakes, exclude inaccuracies',
      () {
        const settings = TacticsSessionSettings();
        expect(settings.accepts(_pos(fen: 'a', mistakeType: '??')), isTrue);
        expect(settings.accepts(_pos(fen: 'b', mistakeType: '?')), isTrue);
        expect(settings.accepts(_pos(fen: 'c', mistakeType: '?!')), isFalse);
      },
    );

    test('1-star positions are excluded unless includeOneStar', () {
      const excluded = TacticsSessionSettings();
      const included = TacticsSessionSettings(includeOneStar: true);
      final oneStar = _pos(fen: 'a', rating: 1);
      expect(excluded.accepts(oneStar), isFalse);
      expect(included.accepts(oneStar), isTrue);
    });

    test('skipReviewed excludes positions already reviewed', () {
      const skip = TacticsSessionSettings(skipReviewed: true);
      expect(skip.accepts(_pos(fen: 'a', reviewCount: 0)), isTrue);
      expect(skip.accepts(_pos(fen: 'b', reviewCount: 3)), isFalse);
    });

    test('countMatching matches the number that would enter a session', () {
      const settings = TacticsSessionSettings();
      final positions = [
        _pos(fen: '1', mistakeType: '??'), // included
        _pos(fen: '2', mistakeType: '?'), // included
        _pos(fen: '3', mistakeType: '?!'), // excluded (inaccuracy)
        _pos(fen: '4', mistakeType: '??', rating: 1), // excluded (1-star)
      ];
      // The "ready" count shown on the Start button must reflect exactly the
      // filtered set — here 2 of 4 — so the label can never disagree with the
      // session that actually launches.
      expect(settings.countMatching(positions), 2);
    });

    test('mistakeTypes filter is honoured exactly', () {
      const blundersOnly = TacticsSessionSettings(mistakeTypes: {'??'});
      final positions = [
        _pos(fen: '1', mistakeType: '??'),
        _pos(fen: '2', mistakeType: '?'),
        _pos(fen: '3', mistakeType: '?!'),
      ];
      expect(blundersOnly.countMatching(positions), 1);
    });
  });

  group('recency window (maxAgeDays)', () {
    test('defaults to 14 days and filters out older games', () {
      const settings = TacticsSessionSettings();
      expect(settings.maxAgeDays, 14);
      expect(
        settings.accepts(_pos(fen: 'old', gameDate: '2024.01.01')),
        isFalse,
      );
      expect(settings.accepts(_pos(fen: 'new')), isTrue);
    });

    test('window boundaries: today counts as day 1', () {
      const today = TacticsSessionSettings(maxAgeDays: 1);
      final now = DateTime.now();
      expect(today.accepts(_pos(fen: 'a', gameDate: _dateStr(now))), isTrue);
      expect(
        today.accepts(
          _pos(
            fen: 'b',
            gameDate: _dateStr(now.subtract(const Duration(days: 1))),
          ),
        ),
        isFalse,
      );

      const twoDays = TacticsSessionSettings(maxAgeDays: 2);
      expect(
        twoDays.accepts(
          _pos(
            fen: 'c',
            gameDate: _dateStr(now.subtract(const Duration(days: 1))),
          ),
        ),
        isTrue,
      );
      expect(
        twoDays.accepts(
          _pos(
            fen: 'd',
            gameDate: _dateStr(now.subtract(const Duration(days: 2))),
          ),
        ),
        isFalse,
      );
    });

    test('null means all time', () {
      const allTime = TacticsSessionSettings(maxAgeDays: null);
      expect(allTime.accepts(_pos(fen: 'a', gameDate: '2020.01.01')), isTrue);
    });

    test('custom puzzles and unparseable dates are never age-filtered', () {
      const settings = TacticsSessionSettings(
        maxAgeDays: 1,
        mistakeTypes: {'??', TacticsSessionSettings.customMistakeType},
      );
      expect(
        settings.accepts(
          _pos(
            fen: 'custom',
            mistakeType: TacticsSessionSettings.customMistakeType,
            gameDate: '2020.01.01',
          ),
        ),
        isTrue,
      );
      expect(settings.accepts(_pos(fen: 'nodate', gameDate: '')), isTrue);
      expect(
        settings.accepts(_pos(fen: 'weird', gameDate: '????.??.??')),
        isTrue,
      );
    });

    test('copyWith sets and clears the window', () {
      const settings = TacticsSessionSettings();
      expect(settings.copyWith(maxAgeDays: 7).maxAgeDays, 7);
      expect(settings.copyWith(clearMaxAgeDays: true).maxAgeDays, isNull);
      expect(
        settings.copyWith(order: TacticsSessionOrder.random).maxAgeDays,
        14,
        reason: 'unrelated copyWith keeps the window',
      );
    });
  });

  group('persistence', () {
    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
    });

    test('maxAgeDays round-trips, with 0 encoding "all time"', () async {
      await const TacticsSessionSettings(maxAgeDays: 7).save();
      expect((await TacticsSessionSettings.load()).maxAgeDays, 7);

      await const TacticsSessionSettings(maxAgeDays: null).save();
      expect((await TacticsSessionSettings.load()).maxAgeDays, isNull);
    });

    test('missing key falls back to the 14-day default', () async {
      expect((await TacticsSessionSettings.load()).maxAgeDays, 14);
    });
  });

  group('TacticsPosition.gameDateTime', () {
    TacticsPosition withDate(String date) => _pos(fen: 'x', gameDate: date);

    test('parses PGN dates', () {
      expect(withDate('2026.07.09').gameDateTime, DateTime(2026, 7, 9));
    });

    test('rejects placeholders and garbage', () {
      expect(withDate('').gameDateTime, isNull);
      expect(withDate('????.??.??').gameDateTime, isNull);
      expect(withDate('2026.13.40').gameDateTime, isNull);
      expect(withDate('July 9, 2026').gameDateTime, isNull);
    });
  });
}

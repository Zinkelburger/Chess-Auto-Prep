import 'package:chess_auto_prep/models/analysis_player_info.dart';
import 'package:chess_auto_prep/services/opponent_list.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/services/games_library/game_filter.dart';

/// The opponent list is the hand-off from the Python prep tooling to Player
/// Analysis. These pin the parse contract on both the documented envelope and
/// the bare-array shorthand, and how an opponent becomes a player entry.
void main() {
  const envelope = '''
{
  "format": "chess-auto-prep/opponents@1",
  "event": "Spring Open 2026",
  "opponents": [
    {"name": "Jane Doe", "chesscom": "janed", "lichess": "jd_li",
     "rating": 1850, "pairing_prob": 0.42, "most_likely_round": 2},
    {"name": "Bob Roe", "chesscom": "bobr"},
    {"name": "No Account", "rating": 1700},
    {"name": "Bob Roe", "chesscom": "bobr"}
  ]
}
''';

  group('OpponentList.parse', () {
    test('reads the documented envelope', () {
      final list = OpponentList.parse(envelope);
      expect(list.event, 'Spring Open 2026');
      expect(list.opponents.map((o) => o.name), ['Jane Doe', 'Bob Roe']);
      expect(list.opponents.first.pairingProb, 0.42);
      expect(list.opponents.first.mostLikelyRound, 2);
      expect(list.opponents.first.rating, 1850);
    });

    test('reports skipped rows instead of dropping them silently', () {
      final list = OpponentList.parse(envelope);
      expect(list.warnings, hasLength(2));
      expect(list.warnings[0], contains('No Account'));
      expect(list.warnings[1], contains('listed twice'));
    });

    test('accepts a bare array with no envelope', () {
      final list = OpponentList.parse(
        '[{"name": "A", "lichess": "a1"}, {"name": "B", "chesscom": "b1"}]',
      );
      expect(list.event, isNull);
      expect(list.opponents, hasLength(2));
      expect(list.opponents.first.accounts, [
        const PlayerAccount('lichess', 'a1'),
      ]);
    });

    test('accepts the long-form username keys the roster uses', () {
      final list = OpponentList.parse(
        '[{"name": "A", "chesscom_username": "a1", "lichess_username": "a2"}]',
      );
      expect(list.opponents.single.accounts, hasLength(2));
    });

    test('rejects a foreign format tag', () {
      expect(
        () => OpponentList.parse('{"format": "other@9", "opponents": []}'),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects non-JSON and shapeless JSON', () {
      expect(
        () => OpponentList.parse('Jane Doe, janed'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => OpponentList.parse('{"event": "x"}'),
        throwsA(isA<FormatException>()),
      );
      expect(() => OpponentList.parse('[]'), throwsA(isA<FormatException>()));
    });
  });

  group('OpponentEntry → AnalysisPlayerInfo', () {
    test(
      'stores the person first and every handle after, semicolon-joined',
      () {
        final entry = OpponentList.parse(envelope).opponents.first;
        expect(entry.playerName, 'Jane Doe; janed; jd_li');

        final info = entry.toPlayerInfo(
          group: 'Spring Open 2026',
          maxGames: 100,
          monthsBack: 6,
          speeds: {GameSpeed.bullet, GameSpeed.blitz},
        );
        expect(info.platform, 'import');
        expect(info.speeds, {GameSpeed.bullet, GameSpeed.blitz});
        expect(info.username, 'Jane Doe; janed; jd_li');
        expect(info.displayName, 'Jane Doe');
        expect(info.group, 'Spring Open 2026');
        expect(info.accounts, [
          const PlayerAccount('chesscom', 'janed'),
          const PlayerAccount('lichess', 'jd_li'),
        ]);
        expect(info.canRedownload, isTrue);
        expect(info.platformDisplayName, 'Chess.com + Lichess');
      },
    );

    test('does not repeat a handle that equals the name', () {
      final entry = OpponentList.parse(
        '[{"name": "janed", "chesscom": "JaneD"}]',
      ).opponents.single;
      expect(entry.playerName, 'janed');
    });
  });

  group('AnalysisPlayerInfo accounts/group', () {
    test('round-trip through JSON', () {
      const info = AnalysisPlayerInfo(
        platform: 'import',
        username: 'Jane Doe; janed',
        accounts: [PlayerAccount('chesscom', 'janed')],
        group: 'Spring Open',
        monthsBack: 6,
      );
      final back = AnalysisPlayerInfo.fromJson(info.toJson());
      expect(back.accounts, info.accounts);
      expect(back.group, 'Spring Open');
      expect(back.platformDisplayName, 'Chess.com');
      expect(back.rangeDescription, 'last 6 months');
    });

    test('legacy JSON without the fields still loads', () {
      final back = AnalysisPlayerInfo.fromJson({
        'platform': 'chesscom',
        'username': 'hikaru',
      });
      expect(back.accounts, isEmpty);
      expect(back.group, isNull);
      expect(back.canRedownload, isTrue);
      expect(back.displayName, 'hikaru');
    });

    test('a PGN-file import still cannot be re-downloaded', () {
      const info = AnalysisPlayerInfo(platform: 'import', username: 'Book');
      expect(info.canRedownload, isFalse);
      expect(info.rangeDescription, 'imported PGN');
      expect(info.platformDisplayName, 'PGN file');
    });
  });
}

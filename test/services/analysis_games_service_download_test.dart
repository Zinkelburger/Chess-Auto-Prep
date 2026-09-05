import 'package:chess_auto_prep/models/analysis_player_info.dart';
import 'package:chess_auto_prep/services/analysis_games_service.dart';
import 'package:chess_auto_prep/services/games_library/game_filter.dart';
import 'package:flutter_test/flutter_test.dart';

/// [AnalysisGamesService.downloadGamesFor] is the one entry point every
/// (re-)download goes through; an opponent built from two accounts must come
/// back as one merged PGN, and a PGN-file import must be refused.
class _FakeService extends AnalysisGamesService {
  final calls = <String>[];
  final speedsSeen = <Set<GameSpeed>>[];

  @override
  Future<String> downloadChesscomGames(
    String username, {
    int maxGames = 100,
    int? monthsBack,
    Set<GameSpeed> speeds = defaultDownloadSpeeds,
    void Function(String)? onProgress,
  }) async {
    calls.add('chesscom:$username:$maxGames:$monthsBack');
    speedsSeen.add(speeds);
    onProgress?.call('fetching');
    return username == 'empty'
        ? ''
        : '[Site "Chess.com"]\n[White "$username"]\n\n1. e4 *';
  }

  @override
  Future<String> downloadLichessGames(
    String username, {
    int maxGames = 100,
    int? monthsBack,
    Set<GameSpeed> speeds = defaultDownloadSpeeds,
    void Function(String)? onProgress,
  }) async {
    calls.add('lichess:$username:$maxGames:$monthsBack');
    speedsSeen.add(speeds);
    return '[Site "lichess"]\n[White "$username"]\n\n1. d4 *';
  }
}

void main() {
  test('a plain download uses the one live account', () async {
    final svc = _FakeService();
    final pgn = await svc.downloadGamesFor(
      const AnalysisPlayerInfo(platform: 'lichess', username: 'hikaru'),
      monthsBack: 3,
    );
    expect(svc.calls, ['lichess:hikaru:100:3']);
    expect(pgn, contains('[White "hikaru"]'));
  });

  test('an opponent merges every account into one PGN', () async {
    final svc = _FakeService();
    final messages = <String>[];
    final pgn = await svc.downloadGamesFor(
      const AnalysisPlayerInfo(
        platform: 'import',
        username: 'Jane Doe; janed; jd_li',
        maxGames: 50,
        accounts: [
          PlayerAccount('chesscom', 'janed'),
          PlayerAccount('lichess', 'jd_li'),
        ],
      ),
      monthsBack: 6,
      onProgress: messages.add,
    );
    expect(svc.calls, ['chesscom:janed:50:6', 'lichess:jd_li:50:6']);
    expect(pgn, contains('[White "janed"]'));
    expect(pgn, contains('[White "jd_li"]'));
    // Progress lines say which account they are about.
    expect(messages, contains('janed: fetching'));
  });

  test('an account with no games does not poison the merge', () async {
    final svc = _FakeService();
    final pgn = await svc.downloadGamesFor(
      const AnalysisPlayerInfo(
        platform: 'import',
        username: 'X; empty; x_li',
        accounts: [
          PlayerAccount('chesscom', 'empty'),
          PlayerAccount('lichess', 'x_li'),
        ],
      ),
    );
    expect(pgn.trim(), startsWith('[Site "lichess"]'));
  });

  test('the player’s own time controls reach every account', () async {
    final svc = _FakeService();
    await svc.downloadGamesFor(
      const AnalysisPlayerInfo(
        platform: 'import',
        username: 'X; a; b',
        speeds: {GameSpeed.bullet, GameSpeed.blitz},
        accounts: [
          PlayerAccount('chesscom', 'a'),
          PlayerAccount('lichess', 'b'),
        ],
      ),
    );
    expect(svc.speedsSeen, [
      {GameSpeed.bullet, GameSpeed.blitz},
      {GameSpeed.bullet, GameSpeed.blitz},
    ]);
  });

  test('a plain download keeps everything but bullet by default', () async {
    final svc = _FakeService();
    await svc.downloadGamesFor(
      const AnalysisPlayerInfo(platform: 'chesscom', username: 'hikaru'),
    );
    expect(svc.speedsSeen.single, defaultDownloadSpeeds);
    expect(svc.speedsSeen.single, isNot(contains(GameSpeed.bullet)));
  });

  group('the download-side filter', () {
    String game(String? tc) =>
        '${tc == null ? '' : '[TimeControl "$tc"]\n'}[White "x"]\n\n1. e4 *';

    test('keeps the chosen buckets and drops the rest', () {
      expect(keepsGameSpeed(game('60'), defaultDownloadSpeeds), isFalse);
      expect(keepsGameSpeed(game('180'), defaultDownloadSpeeds), isTrue);
      expect(keepsGameSpeed(game('60'), {GameSpeed.bullet}), isTrue);
      expect(keepsGameSpeed(game('600'), {GameSpeed.bullet}), isFalse);
      // Chess.com Daily: days per move.
      expect(keepsGameSpeed(game('1/259200'), defaultDownloadSpeeds), isTrue);
      expect(keepsGameSpeed(game('1/259200'), {GameSpeed.blitz}), isFalse);
    });

    test('never drops a game it cannot classify', () {
      expect(keepsGameSpeed(game(null), {GameSpeed.classical}), isTrue);
      expect(keepsGameSpeed(game('?'), {GameSpeed.classical}), isTrue);
    });

    test('spells the Lichess perf types the way the API does', () {
      expect(
        lichessPerfTypes(defaultDownloadSpeeds),
        'blitz,rapid,classical,correspondence',
      );
      expect(
        lichessPerfTypes({GameSpeed.ultraBullet, GameSpeed.bullet}),
        'ultraBullet,bullet',
      );
    });
  });

  test('a PGN-file import has no source and is refused', () async {
    final svc = _FakeService();
    expect(
      () => svc.downloadGamesFor(
        const AnalysisPlayerInfo(platform: 'import', username: 'Book'),
      ),
      throwsStateError,
    );
    expect(svc.calls, isEmpty);
  });
}

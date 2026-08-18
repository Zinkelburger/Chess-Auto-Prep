import 'package:chess_auto_prep/models/analysis_player_info.dart';
import 'package:chess_auto_prep/services/analysis_games_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// [AnalysisGamesService.downloadGamesFor] is the one entry point every
/// (re-)download goes through; an opponent built from two accounts must come
/// back as one merged PGN, and a PGN-file import must be refused.
class _FakeService extends AnalysisGamesService {
  final calls = <String>[];

  @override
  Future<String> downloadChesscomGames(
    String username, {
    int maxGames = 100,
    int? monthsBack,
    void Function(String)? onProgress,
  }) async {
    calls.add('chesscom:$username:$maxGames:$monthsBack');
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
    void Function(String)? onProgress,
  }) async {
    calls.add('lichess:$username:$maxGames:$monthsBack');
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

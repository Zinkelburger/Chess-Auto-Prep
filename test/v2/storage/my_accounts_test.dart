import 'package:chess_auto_prep/v2/chess/tactics/game_ids.dart';
import 'package:chess_auto_prep/v2/storage/my_accounts.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final accounts = PreferencesAccounts();

  test('reads the usernames and dates the old app saved', () async {
    SharedPreferences.setMockInitialValues({
      'lichess_username': 'Me',
      'lichess_last_fetch_ms': DateTime(2026, 9, 1).millisecondsSinceEpoch,
      'chesscom_username': '  ',
    });
    final read = await accounts.read();
    expect(read.keys, [GameSite.lichess]);
    expect(read[GameSite.lichess]?.username, 'Me');
    expect(read[GameSite.lichess]?.downloaded, DateTime(2026, 9, 1));
  });

  test('writes under the same keys; another name forgets the date, the same '
      'name keeps it', () async {
    SharedPreferences.setMockInitialValues({
      'chesscom_username': 'old',
      'chesscom_last_fetch_ms': 5,
    });
    final prefs = await SharedPreferences.getInstance();

    expect(await accounts.setUsername(GameSite.chesscom, ' old '), isTrue);
    expect(prefs.getInt('chesscom_last_fetch_ms'), 5);

    expect(await accounts.setUsername(GameSite.chesscom, 'new'), isTrue);
    expect(prefs.getString('chesscom_username'), 'new');
    expect(prefs.getInt('chesscom_last_fetch_ms'), isNull);

    await accounts.setDownloaded(GameSite.chesscom, DateTime(2026, 9, 22));
    expect(
      prefs.getInt('chesscom_last_fetch_ms'),
      DateTime(2026, 9, 22).millisecondsSinceEpoch,
    );

    expect(await accounts.setUsername(GameSite.chesscom, ''), isTrue);
    expect(prefs.containsKey('chesscom_username'), isFalse);
  });
}

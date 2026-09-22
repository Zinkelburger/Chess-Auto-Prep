import 'package:shared_preferences/shared_preferences.dart';

import '../chess/tactics/game_ids.dart';
import '../diagnostics/log.dart';

/// The user's Lichess and Chess.com usernames and when each account's games
/// last came down.
///
/// The same SharedPreferences keys the old app keeps them under, so a
/// username typed in either app is the one both download for. The old app
/// writes a key only when the user saves a name or a download lands, and
/// preferences write one key at a time, so the two apps never half-write a
/// value; the last save wins, as it would within one app.
const _usernameKeys = {
  GameSite.lichess: 'lichess_username',
  GameSite.chesscom: 'chesscom_username',
};
const _downloadedKeys = {
  GameSite.lichess: 'lichess_last_fetch_ms',
  GameSite.chesscom: 'chesscom_last_fetch_ms',
};

/// One account as the preferences hold it.
final class Account {
  const Account(this.username, {this.downloaded});

  final String username;

  /// When its games last came down; null when they never have.
  final DateTime? downloaded;
}

abstract interface class AccountStore {
  /// The accounts that have a username. Unreadable preferences read as
  /// none, and the log says why.
  Future<Map<GameSite, Account>> read();

  /// Keeps [username] for [site], or forgets it when blank. A different
  /// name forgets the last download too: it was another account's.
  /// Answers whether the preferences took it.
  Future<bool> setUsername(GameSite site, String? username);

  Future<bool> setDownloaded(GameSite site, DateTime when);
}

final class PreferencesAccounts implements AccountStore {
  PreferencesAccounts({
    Future<SharedPreferences> Function() preferences =
        SharedPreferences.getInstance,
  }) : _preferences = preferences;

  final Future<SharedPreferences> Function() _preferences;

  @override
  Future<Map<GameSite, Account>> read() async {
    try {
      final prefs = await _preferences();
      return {
        for (final site in GameSite.values)
          if (prefs.getString(_usernameKeys[site]!)?.trim() case final name?
              when name.isNotEmpty)
            site: Account(name, downloaded: _date(prefs, site)),
      };
    } on Object catch (error) {
      log.w('read the game accounts', error);
      return const {};
    }
  }

  static DateTime? _date(SharedPreferences prefs, GameSite site) {
    final ms = prefs.getInt(_downloadedKeys[site]!);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  @override
  Future<bool> setUsername(GameSite site, String? username) async {
    final name = username?.trim() ?? '';
    try {
      final prefs = await _preferences();
      final key = _usernameKeys[site]!;
      if ((prefs.getString(key)?.trim() ?? '') == name) return true;
      final downloaded = await prefs.remove(_downloadedKeys[site]!);
      final saved = name.isEmpty
          ? await prefs.remove(key)
          : await prefs.setString(key, name);
      return saved && downloaded;
    } on Object catch (error) {
      log.w('save the ${site.label} username', error);
      return false;
    }
  }

  @override
  Future<bool> setDownloaded(GameSite site, DateTime when) async {
    try {
      final prefs = await _preferences();
      return await prefs.setInt(
        _downloadedKeys[site]!,
        when.millisecondsSinceEpoch,
      );
    } on Object catch (error) {
      log.w('save when ${site.label} games came down', error);
      return false;
    }
  }
}

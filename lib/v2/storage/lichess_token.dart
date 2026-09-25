import 'package:shared_preferences/shared_preferences.dart';

import '../diagnostics/log.dart';

/// Where the Lichess account is kept.
///
/// The same SharedPreferences keys the old app writes when the user signs
/// in, so both apps see one account and `v2` never asks the user to sign in
/// again — one app at a time, since the preferences are written whole from
/// each process's cache (see `my_accounts.dart`). The token is only ever handed to the client that puts it in an
/// `Authorization` header; it is never logged, and a failure here says only
/// that the keys could not be read.
const lichessTokenKey = 'lichess_access_token';
const lichessUsernameKey = 'lichess_auth_username';
const lichessExpiryKey = 'lichess_token_expiry';
const lichessPersonalKey = 'lichess_is_pat';

/// The old app also kept a refresh token; Lichess never issues one, and the
/// key is removed on every write so a stale one cannot linger.
const _lichessRefreshKey = 'lichess_refresh_token';

/// A signed-in Lichess account as the preferences hold it.
final class LichessAccount {
  const LichessAccount({
    required this.token,
    required this.username,
    this.until,
    this.personal = false,
  });

  /// The bearer token. Never logged, never shown in full.
  final String token;

  /// The account's name as Lichess spells it; null when the account was
  /// saved before the name could be fetched.
  final String? username;

  /// When an OAuth token stops working; null for a personal access token,
  /// which lasts until revoked.
  final DateTime? until;

  /// Typed in as a personal access token rather than obtained by logging in.
  final bool personal;

  bool expiredAt(DateTime now) => until != null && now.isAfter(until!);
}

/// The saved account, or null when there is none. A read that fails, or
/// keys of the wrong type, are treated as signed out: public downloads work
/// without an account, and the user can sign in again. Keys of the wrong
/// type are removed so they cannot fail every later read. An OAuth token
/// past its expiry is also cleared, as the old app does on start.
Future<LichessAccount?> readLichessAccount({DateTime? now}) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.get(lichessTokenKey);
    if (token == null || token == '') return null;
    final username = prefs.get(lichessUsernameKey);
    final expiry = prefs.get(lichessExpiryKey);
    final personal = prefs.get(lichessPersonalKey);
    if (token is! String ||
        (username != null && username is! String) ||
        (expiry != null && expiry is! int) ||
        (personal != null && personal is! bool)) {
      log.w('read the saved Lichess account', 'malformed keys were removed');
      await writeLichessAccount(null);
      return null;
    }
    final account = LichessAccount(
      token: token,
      username: username as String?,
      until: expiry == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(expiry as int),
      personal: personal as bool? ?? false,
    );
    if (!account.personal && account.expiredAt(now ?? DateTime.now())) {
      log.w('read the saved Lichess account', 'the token has expired');
      await writeLichessAccount(null);
      return null;
    }
    return account;
  } on Object catch (error) {
    // The token must never reach the log; name only the kind of failure.
    log.w('read the saved Lichess account', error.runtimeType);
    return null;
  }
}

/// Keeps [account], or forgets the saved one when [account] is null.
/// Answers whether the preferences took it.
///
/// Every key is changed before the first await, so the in-memory cache
/// never holds half of one account and half of another.
Future<bool> writeLichessAccount(LichessAccount? account) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final name = account?.username;
    final until = account?.until;
    final writes = account == null
        ? [
            for (final key in [
              lichessTokenKey,
              lichessUsernameKey,
              lichessExpiryKey,
              lichessPersonalKey,
              _lichessRefreshKey,
            ])
              prefs.remove(key),
          ]
        : [
            prefs.setString(lichessTokenKey, account.token),
            prefs.remove(_lichessRefreshKey),
            prefs.setBool(lichessPersonalKey, account.personal),
            name == null
                ? prefs.remove(lichessUsernameKey)
                : prefs.setString(lichessUsernameKey, name),
            until == null
                ? prefs.remove(lichessExpiryKey)
                : prefs.setInt(lichessExpiryKey, until.millisecondsSinceEpoch),
          ];
    return (await Future.wait(writes)).every((saved) => saved);
  } on Object catch (error) {
    log.w('save the Lichess account', error.runtimeType);
    return false;
  }
}

/// The user's Lichess token, or null when they have not signed in. What
/// every Lichess client is handed, read at each call so that signing in
/// between two attempts is enough.
Future<String?> readLichessToken() async => (await readLichessAccount())?.token;

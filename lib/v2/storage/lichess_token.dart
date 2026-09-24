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

/// The saved account, or null when there is none — and also when the
/// preferences could not be read, because a public study download works
/// without one and the failure is named in the log either way. An OAuth
/// token past its expiry is reported as no account and cleared, as the old
/// app does on start: Lichess will refuse it and the user must log in again.
Future<LichessAccount?> readLichessAccount({DateTime? now}) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString(lichessTokenKey);
    if (token == null || token.isEmpty) return null;
    final expiry = prefs.getInt(lichessExpiryKey);
    final account = LichessAccount(
      token: token,
      username: prefs.getString(lichessUsernameKey),
      until: expiry == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(expiry),
      personal: prefs.getBool(lichessPersonalKey) ?? false,
    );
    if (!account.personal && account.expiredAt(now ?? DateTime.now())) {
      log.w('read the saved Lichess account', 'the token has expired');
      await writeLichessAccount(null);
      return null;
    }
    return account;
  } on Object catch (error) {
    log.w('read the saved Lichess account', error);
    return null;
  }
}

/// Keeps [account], or forgets the saved one when [account] is null.
/// Answers whether the preferences took it.
Future<bool> writeLichessAccount(LichessAccount? account) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    if (account == null) {
      var ok = true;
      for (final key in [
        lichessTokenKey,
        lichessUsernameKey,
        lichessExpiryKey,
        lichessPersonalKey,
        _lichessRefreshKey,
      ]) {
        ok = await prefs.remove(key) && ok;
      }
      return ok;
    }
    final name = account.username;
    final until = account.until;
    final writes = [
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
    // All accepted writes must settle before an error permits a retry.
    final results = await Future.wait(writes);
    return results.every((saved) => saved);
  } on Object {
    log.w('save the Lichess account', 'the preferences write failed');
    return false;
  }
}

/// The user's Lichess token, or null when they have not signed in. What
/// every Lichess client is handed, read at each call so that signing in
/// between two attempts is enough.
Future<String?> readLichessToken() async => (await readLichessAccount())?.token;

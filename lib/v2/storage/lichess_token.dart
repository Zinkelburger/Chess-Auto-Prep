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

/// A credential read failed; deliberately carries no token or backend error.
final class LichessAccountUnavailable implements Exception {
  const LichessAccountUnavailable();

  @override
  String toString() => 'The saved Lichess account could not be read.';
}

// One process owns the legacy preference keys. Reads, writes and expiry
// removal share this queue so a delayed removal cannot erase a newer grant.
Future<void> _credentialTail = Future.value();
SharedPreferences? _unconfirmed;
SharedPreferences? _expiryRemoval;

Future<T> _access<T>(Future<T> Function() action) {
  final next = _credentialTail.then((_) => action());
  _credentialTail = next.then<void>((_) {}, onError: (Object _) {});
  return next;
}

/// Null means absent or successfully removed after expiry. An unavailable
/// read is explicit, and an optimistic cache from a failed write is never
/// handed to clients as a confirmed token. The keys retain their v1 format.
Future<LichessAccount?> readLichessAccount({DateTime? now}) =>
    _access(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        if (identical(_expiryRemoval, prefs)) {
          if (!await _writeAccount(prefs, null)) {
            throw const LichessAccountUnavailable();
          }
          _expiryRemoval = null;
        }
        if (identical(_unconfirmed, prefs)) {
          throw const LichessAccountUnavailable();
        }
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
          _expiryRemoval = prefs;
          if (!await _writeAccount(prefs, null)) {
            throw const LichessAccountUnavailable();
          }
          _expiryRemoval = null;
          return null;
        }
        return account;
      } on Object {
        log.w('read the saved Lichess account', 'the preferences read failed');
        throw const LichessAccountUnavailable();
      }
    });

/// Keeps [account], or forgets the saved one when [account] is null.
/// Answers whether the preferences took it.
Future<bool> writeLichessAccount(LichessAccount? account) => _access(() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    // An explicit accepted account supersedes automatic expiry cleanup.
    if (identical(_expiryRemoval, prefs)) _expiryRemoval = null;
    return await _writeAccount(prefs, account);
  } on Object {
    log.w('save the Lichess account', 'the preferences write failed');
    return false;
  }
});

Future<bool> _writeAccount(
  SharedPreferences prefs,
  LichessAccount? account,
) async {
  // SharedPreferences mutates its cache before the platform acknowledges.
  _unconfirmed = prefs;
  try {
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
      if (ok) _unconfirmed = null;
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
    final ok = results.every((saved) => saved);
    if (ok) _unconfirmed = null;
    return ok;
  } on Object {
    log.w('save the Lichess account', 'the preferences write failed');
    return false;
  }
}

/// The user's Lichess token, or null when they have not signed in. What
/// every Lichess client is handed, read at each call so that signing in
/// between two attempts is enough.
Future<String?> readLichessToken() async {
  try {
    return (await readLichessAccount())?.token;
  } on LichessAccountUnavailable {
    // Public clients can still try anonymously. Settings keeps the explicit
    // unavailable state and offers a read retry instead of showing signed out.
    return null;
  }
}

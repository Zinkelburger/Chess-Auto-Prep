import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../chess/tactics/game_ids.dart';
import '../diagnostics/log.dart';

/// The user's Lichess and Chess.com usernames and when each account's games
/// last came down.
///
/// The same SharedPreferences keys the old app keeps them under, so a
/// username typed in either app is the one both download for. The two apps
/// must not run at once on one profile: the preferences plugin reads the
/// whole file once per process and writes its whole cached map on every
/// save, so each app's next save would put back the values it started
/// with, the other app's changes lost. The desktop runner keeps one
/// instance per session, which is what prevents that; forcing a second
/// one (`CHESS_AUTO_PREP_NEW_INSTANCE=1`) on the real profile is not safe.
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

sealed class AccountsRead {
  const AccountsRead();
}

/// Names and one owner's admission revision, captured as an immutable value.
final class AccountsSnapshot extends AccountsRead {
  AccountsSnapshot({
    required Map<GameSite, Account> accounts,
    required this.revision,
  }) : accounts = Map.unmodifiable(accounts);
  final Map<GameSite, Account> accounts;
  final int revision;
}

final class AccountsUnavailable extends AccountsRead {
  const AccountsUnavailable(this.detail);
  final String detail;
}

abstract interface class AccountStore {
  /// Changes synchronously on username admission and observed names/validity
  /// changes. Download timestamps do not determine comparison membership.
  int get revision;
  Future<AccountsRead> snapshot();

  /// The accounts that have a username. Unreadable preferences read as
  /// none, and the log says why.
  Future<Map<GameSite, Account>> read();

  /// Keeps [username] for [site], or forgets it when blank. A different
  /// name forgets the last download too: it was another account's.
  /// Answers whether the preferences took it.
  Future<bool> setUsername(GameSite site, String? username);

  Future<bool> setDownloaded(
    GameSite site,
    DateTime when, {
    String? expectedUsername,
  });
}

final class PreferencesAccounts implements AccountStore {
  PreferencesAccounts({this._preferences = SharedPreferences.getInstance});

  final Future<SharedPreferences> Function() _preferences;

  int _revision = 0;
  int _pendingUsernames = 0;
  final _unconfirmed = <GameSite>{};
  Map<GameSite, String>? _names;
  bool? _readable;
  Future<void> _usernameTail = Future.value();
  Future<AccountsRead>? _reading;
  // The preferences plugin mutates its cache before platform acknowledgement.
  // Retain the last acknowledged timestamp while a date write is uncertain.
  final _dates = <GameSite, ({String username, DateTime? date})>{};

  @override
  int get revision => _revision;

  @override
  Future<AccountsRead> snapshot() {
    if (_pendingUsernames != 0 || _unconfirmed.isNotEmpty) {
      return Future.value(
        _unavailable(
          'Account changes have not been confirmed. Retry saving the usernames.',
        ),
      );
    }
    final reading = _reading;
    if (reading != null) return reading;
    final next = _capture();
    _reading = next;
    unawaited(
      next.whenComplete(() {
        if (identical(_reading, next)) _reading = null;
      }),
    );
    return next;
  }

  Future<AccountsRead> _capture() async {
    final started = _revision;
    try {
      final prefs = await _preferences();
      if (started != _revision) {
        return const AccountsUnavailable(
          'Accounts changed during the read. Retry.',
        );
      }
      final accounts = {
        for (final site in GameSite.values)
          if (prefs.getString(_usernameKeys[site]!)?.trim() case final name?
              when name.isNotEmpty)
            site: Account(name, downloaded: _confirmedDate(prefs, site, name)),
      };
      final changed =
          _names == null ||
          _names!.length != accounts.length ||
          accounts.entries.any(
            (entry) => _names![entry.key] != entry.value.username,
          );
      if (changed || _readable != true) _revision++;
      _readable = true;
      _names = {
        for (final entry in accounts.entries) entry.key: entry.value.username,
      };
      return AccountsSnapshot(accounts: accounts, revision: _revision);
    } on Object catch (error) {
      log.w('read the game accounts', error);
      if (started != _revision) {
        return const AccountsUnavailable(
          'Accounts changed during the read. Retry.',
        );
      }
      return _unavailable('The saved accounts could not be read.');
    }
  }

  AccountsUnavailable _unavailable(String detail) {
    if (_readable != false) _revision++;
    _readable = false;
    return AccountsUnavailable(detail);
  }

  @override
  Future<Map<GameSite, Account>> read() async => switch (await snapshot()) {
    AccountsSnapshot(:final accounts) => accounts,
    AccountsUnavailable() => const {},
  };

  static DateTime? _date(SharedPreferences prefs, GameSite site) {
    final ms = prefs.getInt(_downloadedKeys[site]!);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  DateTime? _confirmedDate(
    SharedPreferences prefs,
    GameSite site,
    String name,
  ) {
    final held = _dates[site];
    return held?.username == name ? held!.date : _date(prefs, site);
  }

  @override
  Future<bool> setUsername(GameSite site, String? username) {
    // Admission invalidates a captured comparison before any platform await.
    _revision++;
    _pendingUsernames++;
    _unconfirmed.add(site);
    _reading = null;
    final name = username?.trim() ?? '';
    final written = _usernameTail.then((_) async {
      final success = await _writeUsername(site, name);
      if (success) {
        _unconfirmed.remove(site);
      } else {
        _unconfirmed.add(site);
      }
      return success;
    });
    _usernameTail = written.then((_) {});
    return written.whenComplete(() => _pendingUsernames--);
  }

  Future<bool> _writeUsername(GameSite site, String name) async {
    try {
      final prefs = await _preferences();
      final key = _usernameKeys[site]!;
      final unchanged = (prefs.getString(key)?.trim() ?? '') == name;
      // A failed platform write already changed the plugin cache. Reissue
      // persistence even when its cached username matches this exact retry.
      final dateKey = _downloadedKeys[site]!;
      final date = unchanged
          ? _confirmedDate(prefs, site, name)?.millisecondsSinceEpoch
          : null;
      final downloaded = date == null
          ? await prefs.remove(dateKey)
          : await prefs.setInt(dateKey, date);
      final saved = name.isEmpty
          ? await prefs.remove(key)
          : await prefs.setString(key, name);
      if (saved && downloaded) _dates.remove(site);
      return saved && downloaded;
    } on Object catch (error) {
      log.w('save the ${site.label} username', error);
      return false;
    }
  }

  @override
  Future<bool> setDownloaded(
    GameSite site,
    DateTime when, {
    String? expectedUsername,
  }) {
    final written = _usernameTail.then(
      (_) => _writeDownloaded(site, when, expectedUsername),
    );
    _usernameTail = written.then((_) {});
    return written;
  }

  Future<bool> _writeDownloaded(
    GameSite site,
    DateTime when,
    String? expectedUsername,
  ) async {
    try {
      final prefs = await _preferences();
      final name = prefs.getString(_usernameKeys[site]!)?.trim() ?? '';
      if (name.isEmpty ||
          (expectedUsername != null && name != expectedUsername)) {
        return false;
      }
      final prior = _confirmedDate(prefs, site, name);
      _dates[site] = (username: name, date: prior);
      final saved = await prefs.setInt(
        _downloadedKeys[site]!,
        when.millisecondsSinceEpoch,
      );
      if (saved) _dates.remove(site);
      return saved;
    } on Object catch (error) {
      log.w('save when ${site.label} games came down', error);
      return false;
    }
  }
}

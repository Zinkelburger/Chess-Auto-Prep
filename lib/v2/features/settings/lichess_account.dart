import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../diagnostics/log.dart';
import '../../net/lichess_login.dart';
import '../../storage/pending_writes.dart';
import '../../storage/lichess_token.dart';

/// The Lichess account as the settings show it: signed out, waiting for
/// the browser, or signed in as someone. The one owner of that state; the
/// Accounts rows read it and call it.
final class LichessAccountState extends ChangeNotifier {
  LichessAccountState({
    required LichessLogin login,
    this.pendingWrites,
    required Future<LichessAccount?> Function() read,
    required Future<bool> Function(LichessAccount?) write,
  }) : _login = login,
       _read = read,
       _write = write;

  /// Lets the way out wait for an account write in flight.
  final PendingWrites? pendingWrites;
  final LichessLogin _login;
  final Future<LichessAccount?> Function() _read;
  final Future<bool> Function(LichessAccount?) _write;

  AccountStatus _status = const SignedOut();
  AccountStatus get status => _status;

  /// The last thing that went wrong, shown until the next attempt.
  String? _problem;
  String? get problem => _problem;

  bool _disposed = false;

  /// A login, token check or logout is under way; another is refused.
  bool _busy = false;

  /// Reads the saved account. Called once when the app starts; an account
  /// that cannot be read shows as signed out.
  Future<void> load() async {
    LichessAccount? saved;
    try {
      saved = await _read();
    } on Object {
      log.w('read the saved Lichess account', 'the preferences read failed');
    }
    if (_busy) return;
    _set(saved == null ? const SignedOut() : SignedIn(saved), problem: null);
  }

  /// Runs the browser flow. Refused while one is already waiting.
  Future<void> logIn() => _once(() async {
    _set(const Connecting(), problem: null);
    final outcome = await _login.logIn(
      waiting: (page, {required opened}) =>
          _set(Connecting(page: page, browserOpened: opened)),
    );
    await _took(outcome);
  }, otherwise: null);

  /// Ends a waiting browser flow; the row goes back to signed out.
  Future<void> cancel() => _login.cancel();

  /// Signs in with a personal access token typed into the row. Answers
  /// whether it was taken.
  Future<bool> useToken(String token) => _once(() async {
    _set(const Checking(), problem: null);
    return _took(await _login.withToken(token));
  }, otherwise: false);

  /// Signs out: the token is revoked at Lichess best effort and forgotten
  /// here whatever Lichess said. When this computer will not forget it,
  /// the row says so: the next launch would read it back as signed in.
  Future<void> logOut() {
    final signedIn = _status;
    if (signedIn is! SignedIn) return Future.value();
    return _once(() async {
      _set(const SigningOut());
      await _login.revoke(signedIn.account.token);
      if (await _save(null)) {
        _set(const SignedOut(), problem: null);
      } else {
        _set(
          const SignedOut(),
          problem:
              'Logged out, but the account could not be removed from this '
              'computer; it may show as logged in next time.',
        );
      }
    }, otherwise: null);
  }

  Future<T> _once<T>(Future<T> Function() work, {required T otherwise}) async {
    if (_disposed || _busy) return otherwise;
    _busy = true;
    try {
      return await work();
    } finally {
      _busy = false;
    }
  }

  Future<bool> _took(LoginOutcome outcome) async {
    switch (outcome) {
      case LoggedIn(account: final grant):
        final account = LichessAccount(
          token: grant.token,
          username: grant.username,
          until: grant.until,
          personal: grant.personal,
        );
        if (!await _save(account)) {
          _set(
            const SignedOut(),
            problem: 'Logged in, but the account could not be saved. '
                'Try again.',
          );
          return false;
        }
        _set(SignedIn(account), problem: null);
        return true;
      case LoginCancelled():
        _set(const SignedOut(), problem: null);
        return false;
      case LoginFailed(:final problem):
        _set(const SignedOut(), problem: problem.sentence);
        return false;
    }
  }

  Future<bool> _save(LichessAccount? account) async {
    final saving = _write(account).catchError((Object _) {
      // The credential must never become part of an exception message.
      log.w('save the Lichess account', 'the preferences write failed');
      return false;
    });
    return pendingWrites?.track(
          this,
          saving,
          label: 'Lichess account',
          problem: (saved) => saved ? null : 'The account could not be saved.',
          obligation: this,
        ) ??
        saving;
  }

  /// [problem] left out keeps the last one; null clears it.
  void _set(AccountStatus status, {Object? problem = _keep}) {
    if (_disposed) return;
    _status = status;
    if (problem != _keep) _problem = problem as String?;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_login.cancel());
    super.dispose();
  }
}

const _keep = Object();

sealed class AccountStatus {
  const AccountStatus();
}

final class SignedOut extends AccountStatus {
  const SignedOut();
}

/// The browser flow is under way. [page] is known once the server is up;
/// [browserOpened] false means the desktop did not take it and the user
/// needs the link.
final class Connecting extends AccountStatus {
  const Connecting({this.page, this.browserOpened = true});

  final Uri? page;
  final bool browserOpened;
}

/// A typed token is being checked with Lichess.
final class Checking extends AccountStatus {
  const Checking();
}

final class SigningOut extends AccountStatus {
  const SigningOut();
}

final class SignedIn extends AccountStatus {
  const SignedIn(this.account);

  final LichessAccount account;
}

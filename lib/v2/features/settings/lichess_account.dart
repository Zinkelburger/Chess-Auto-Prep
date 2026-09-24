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

  /// Reads the saved account. Called once when the app starts.
  Future<void> load() async {
    final saved = await _read();
    _set(saved == null ? const SignedOut() : SignedIn(saved), problem: null);
  }

  /// Runs the browser flow. Refused while one is already waiting.
  Future<void> logIn() =>
      pendingWrites?.track(
        this,
        _logIn(),
        label: 'Lichess account',
        problem: (_) => _problem,
      ) ??
      _logIn();

  Future<void> _logIn() async {
    if (_status is Connecting) return;
    _set(const Connecting(), problem: null);
    final outcome = await _login.logIn(
      waiting: (page, {required opened}) =>
          _set(Connecting(page: page, browserOpened: opened)),
    );
    await _took(outcome);
  }

  /// Ends a waiting browser flow; the row goes back to signed out.
  Future<void> cancel() => _login.cancel();

  /// Signs in with a personal access token typed into the row. Answers
  /// whether it was taken.
  Future<bool> useToken(String token) =>
      pendingWrites?.track(
        this,
        _useToken(token),
        label: 'Lichess account',
        problem: (_) => _problem,
      ) ??
      _useToken(token);

  Future<bool> _useToken(String token) async {
    if (_status is Connecting) return false;
    _set(const Checking(), problem: null);
    return _took(await _login.withToken(token));
  }

  /// Signs out: the token is revoked at Lichess best effort and forgotten
  /// here whatever Lichess said. When this computer will not forget it,
  /// the row says so: the next launch would read it back as signed in.
  Future<void> logOut() =>
      pendingWrites?.track(
        this,
        _logOut(),
        label: 'Lichess account',
        problem: (_) => _problem,
      ) ??
      _logOut();

  Future<void> _logOut() async {
    final signedIn = _status;
    if (signedIn is! SignedIn) return;
    _set(const SigningOut());
    await _login.revoke(signedIn.account.token);
    if (await _write(null)) {
      _set(const SignedOut(), problem: null);
      return;
    }
    log.w('sign out of Lichess', 'the preferences kept the account');
    _set(
      const SignedOut(),
      problem:
          'Logged out, but the account could not be removed from this '
          'computer; it may show as logged in next time.',
    );
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
        if (!await _write(account)) {
          _set(
            const SignedOut(),
            problem:
                'Logged in, but the account could not be saved. '
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

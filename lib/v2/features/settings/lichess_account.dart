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
    PendingWrites? pendingWrites,
    required Future<LichessAccount?> Function() read,
    required Future<bool> Function(LichessAccount?) write,
  }) : pendingWrites = pendingWrites ?? PendingWrites(),
       _login = login,
       _read = read,
       _write = write;

  final PendingWrites pendingWrites;
  final LichessLogin _login;
  final Future<LichessAccount?> Function() _read;
  final Future<bool> Function(LichessAccount?) _write;

  AccountStatus _status = const SignedOut();
  AccountStatus get status => _status;

  /// The last thing that went wrong, shown until the next attempt.
  String? _problem;
  String? get problem => _problem;

  bool _disposed = false;
  bool _working = false;
  int _revision = 0;
  final _requests = Object();
  PendingObligation<bool>? _saving;
  bool _removing = false;

  bool get canRetrySave => _saving != null && !_saving!.committed && !_working;

  /// Reads the saved account. Called once when the app starts.
  Future<void> load() async {
    if (_disposed) return;
    final revision = _revision;
    await pendingWrites.settleFor(this);
    if (_disposed ||
        revision != _revision ||
        pendingWrites.unfinished(this).isNotEmpty)
      return;
    final saved = await _read();
    if (_disposed || revision != _revision) return;
    _set(saved == null ? const SignedOut() : SignedIn(saved), problem: null);
  }

  /// Runs the browser flow. Refused while one is already waiting.
  Future<void> logIn() {
    if (_disposed || _working) return Future.value();
    final work = _logIn();
    pendingWrites.watch(_requests, work);
    return work;
  }

  Future<void> _logIn() async {
    _working = true;
    _revision++;
    try {
      _set(const Connecting(), problem: null);
      final outcome = await _login.logIn(
        waiting: (page, {required opened}) =>
            _set(Connecting(page: page, browserOpened: opened)),
      );
      await _took(outcome);
    } finally {
      _working = false;
      if (!_disposed && canRetrySave) notifyListeners();
    }
  }

  /// Ends a waiting browser flow; the row goes back to signed out.
  Future<void> cancel() => _login.cancel();

  /// Signs in with a personal access token typed into the row. Answers
  /// whether it was taken.
  Future<bool> useToken(String token) {
    if (_disposed || _working) return Future.value(false);
    final work = _useToken(token);
    pendingWrites.watch(_requests, work);
    return work;
  }

  Future<bool> _useToken(String token) async {
    _working = true;
    _revision++;
    try {
      _set(const Checking(), problem: null);
      return await _took(await _login.withToken(token));
    } finally {
      _working = false;
      if (!_disposed && canRetrySave) notifyListeners();
    }
  }

  /// Signs out: the token is revoked at Lichess best effort and forgotten
  /// here whatever Lichess said. When this computer will not forget it,
  /// the row says so: the next launch would read it back as signed in.
  Future<void> logOut() {
    if (_disposed || _working || _status is! SignedIn) return Future.value();
    final work = _logOut();
    pendingWrites.watch(_requests, work);
    return work;
  }

  Future<void> _logOut() async {
    final signedIn = _status as SignedIn;
    _working = true;
    _revision++;
    try {
      _set(const SigningOut());
      await _login.revoke(signedIn.account.token);
      await _persist(null);
    } finally {
      _working = false;
      if (!_disposed && canRetrySave) notifyListeners();
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
        return _persist(account);
      case LoginCancelled():
        _set(const SignedOut(), problem: null);
        return false;
      case LoginFailed(:final problem):
        _set(const SignedOut(), problem: problem.sentence);
        return false;
    }
  }

  Future<bool> _persist(LichessAccount? account) async {
    final earlier = pendingWrites.unfinished(this).isNotEmpty;
    _removing = account == null;
    late final PendingObligation<bool> entry;
    entry = pendingWrites.accept(
      resource: this,
      label: 'Lichess account',
      blocked: () => false,
      work: () async {
        var saved = false;
        try {
          saved = await _write(account);
        } on Object {
          // The credential must never become part of an exception message.
          log.w('save the Lichess account', 'the preferences write failed');
        }
        if (identical(_saving, entry) && saved) {
          _set(
            account == null ? const SignedOut() : SignedIn(account),
            problem: null,
          );
        }
        return saved;
      },
      problem: (saved) => saved ? null : 'The account could not be saved.',
    );
    _saving = entry;
    if (!await entry.run() && earlier) await pendingWrites.retry(this);
    if (!entry.committed) _saveFailed();
    return entry.committed;
  }

  /// Retry only preferences persistence: no new token check or browser flow.
  Future<void> retrySave() async {
    if (_working || _saving == null) return;
    _working = true;
    if (!_disposed) notifyListeners();
    try {
      await pendingWrites.retry(this);
      if (!_saving!.committed) _saveFailed();
    } finally {
      _working = false;
      if (!_disposed) notifyListeners();
    }
  }

  void _saveFailed() => _set(
    const SignedOut(),
    problem: _removing
        ? 'Logged out, but the account could not be removed from this '
              'computer; it may show as logged in next time.'
        : 'Logged in, but the account could not be saved. Retry the save.',
  );

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

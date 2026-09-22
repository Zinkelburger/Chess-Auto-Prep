import 'dart:async';

import 'package:chess_auto_prep/v2/net/lichess_login.dart';
import 'package:chess_auto_prep/v2/storage/lichess_token.dart';

/// A Lichess login that answers what the test says, and remembers what it
/// was asked. The browser flow waits until the test ends it with
/// [browserBack] or the owner cancels it.
final class ScriptedLogin implements LichessLogin {
  ScriptedLogin({
    this.page,
    this.browserOpens = true,
    this.tokenOutcome = const LoginFailed(LoginProblem.tokenRejected),
  });

  Uri? page;
  bool browserOpens;
  LoginOutcome tokenOutcome;

  final revoked = <String>[];
  final tokensTried = <String>[];
  var logins = 0;
  Completer<LoginOutcome>? _waiting;

  bool get waiting => _waiting != null && !_waiting!.isCompleted;

  /// The browser comes back with [outcome].
  void browserBack(LoginOutcome outcome) {
    final waiting = _waiting;
    if (waiting == null || waiting.isCompleted) {
      throw StateError('no login is waiting');
    }
    waiting.complete(outcome);
  }

  @override
  Future<LoginOutcome> logIn({
    required void Function(Uri page, {required bool opened}) waiting,
  }) {
    logins++;
    final completer = Completer<LoginOutcome>();
    _waiting = completer;
    waiting(
      page ?? Uri.parse('https://lichess.org/oauth?x=1'),
      opened: browserOpens,
    );
    return completer.future;
  }

  @override
  Future<void> cancel() async {
    final waiting = _waiting;
    if (waiting != null && !waiting.isCompleted) {
      waiting.complete(const LoginCancelled());
    }
  }

  @override
  Future<LoginOutcome> withToken(String token) async {
    tokensTried.add(token);
    return tokenOutcome;
  }

  @override
  Future<void> revoke(String token) async => revoked.add(token);
}

LichessAccount someone({
  String name = 'DrNykterstein',
  bool personal = false,
}) => LichessAccount(
  token: 'lip_secret',
  username: name,
  until: personal ? null : DateTime(2027, 9, 22),
  personal: personal,
);

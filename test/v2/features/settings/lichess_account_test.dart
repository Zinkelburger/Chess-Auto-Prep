import 'dart:async';

import 'package:chess_auto_prep/v2/features/settings/lichess_account.dart';
import 'package:chess_auto_prep/v2/net/lichess_login.dart';
import 'package:chess_auto_prep/v2/storage/lichess_token.dart';
import 'package:chess_auto_prep/v2/storage/pending_writes.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_login.dart';

void main() {
  late ScriptedLogin login;
  LichessAccount? saved;
  var writeFails = false;
  var notified = 0;
  late PendingWrites pending;

  LichessAccountState owner() {
    final state = LichessAccountState(
      login: login,
      pendingWrites: pending,
      read: () async => saved,
      write: (account) async {
        if (writeFails) return false;
        saved = account;
        return true;
      },
    );
    state.addListener(() => notified++);
    addTearDown(state.dispose);
    return state;
  }

  setUp(() {
    login = ScriptedLogin();
    saved = null;
    writeFails = false;
    notified = 0;
    pending = PendingWrites();
  });

  test('starts signed out, and loads a saved account', () async {
    final state = owner();
    expect(state.status, isA<SignedOut>());
    saved = someone();
    await state.load();
    expect((state.status as SignedIn).account.username, 'DrNykterstein');
  });

  test('logging in waits for the browser, then keeps the account', () async {
    final state = owner();
    final done = state.logIn();
    await Future<void>.delayed(Duration.zero);
    final connecting = state.status as Connecting;
    expect(connecting.page, isNotNull);
    expect(connecting.browserOpened, isTrue);
    login.browserBack(loggedIn());
    await done;
    expect((state.status as SignedIn).account.token, 'lip_secret');
    expect(saved?.username, 'DrNykterstein');
    expect(state.problem, isNull);
  });

  test('a browser that did not open is said so, with the page', () async {
    login.browserOpens = false;
    final state = owner();
    final done = state.logIn();
    await Future<void>.delayed(Duration.zero);
    final connecting = state.status as Connecting;
    expect(connecting.browserOpened, isFalse);
    expect(connecting.page.toString(), startsWith('https://lichess.org/oauth'));
    await state.cancel();
    await done;
    expect(state.status, isA<SignedOut>());
    expect(state.problem, isNull, reason: 'cancelling is not a problem');
  });

  test('a second login while one waits is ignored', () async {
    final state = owner();
    final first = state.logIn();
    await Future<void>.delayed(Duration.zero);
    await state.logIn();
    expect(login.logins, 1);
    login.browserBack(const LoginFailed(LoginProblem.denied));
    await first;
    expect(state.status, isA<SignedOut>());
    expect(state.problem, LoginProblem.denied.sentence);
  });

  test('a failed login names the problem until the next attempt', () async {
    final state = owner();
    final first = state.logIn();
    await Future<void>.delayed(Duration.zero);
    login.browserBack(const LoginFailed(LoginProblem.timedOut));
    await first;
    expect(state.problem, LoginProblem.timedOut.sentence);
    final second = state.logIn();
    await Future<void>.delayed(Duration.zero);
    expect(state.problem, isNull);
    login.browserBack(const LoginCancelled());
    await second;
  });

  test('an account that cannot be saved is not shown as signed in', () async {
    writeFails = true;
    final state = owner();
    final done = state.logIn();
    await Future<void>.delayed(Duration.zero);
    login.browserBack(loggedIn());
    await done;
    expect(state.status, isA<SignedOut>());
    expect(state.problem, contains('could not be saved'));
  });

  test('a personal token is checked, kept, and marked as one', () async {
    login.tokenOutcome = loggedIn(personal: true);
    final state = owner();
    expect(await state.useToken('lip_secret'), isTrue);
    expect(login.tokensTried, ['lip_secret']);
    expect((state.status as SignedIn).account.personal, isTrue);
    expect(saved?.personal, isTrue);
  });

  test('a rejected token says so and stays signed out', () async {
    final state = owner();
    expect(await state.useToken('bad'), isFalse);
    expect(state.status, isA<SignedOut>());
    expect(state.problem, LoginProblem.tokenRejected.sentence);
    expect(
      await pending.settle(),
      isNull,
      reason: 'authentication rejection is not an unsaved account',
    );
  });

  test(
    'successful credential persistence clears its earlier failed snapshot',
    () async {
      login.tokenOutcome = loggedIn(personal: true);
      final state = owner();
      writeFails = true;
      expect(await state.useToken('lip_secret'), isFalse);
      writeFails = false;
      expect(await state.useToken('lip_secret'), isTrue);
      expect(await pending.settle(), isNull);
    },
  );

  test(
    'a write failing after disposal remains an unsaved obligation',
    () async {
      login.tokenOutcome = loggedIn(personal: true);
      final writing = Completer<bool>();
      final state = LichessAccountState(
        login: login,
        pendingWrites: pending,
        read: () async => null,
        write: (_) => writing.future,
      );
      final accepted = state.useToken('lip_secret');
      await pumpEventQueue();
      state.dispose();
      writing.complete(false);
      expect(await accepted, isFalse);
      expect(await pending.settle(), contains('Lichess'));
    },
  );

  test('retry saves the exact grant without asking Lichess again', () async {
    login.tokenOutcome = loggedIn(personal: true);
    writeFails = true;
    final state = owner();
    expect(await state.useToken('lip_secret'), isFalse);
    expect(state.canRetrySave, isTrue);
    writeFails = false;
    await state.retrySave();
    expect(login.tokensTried, ['lip_secret']);
    expect(saved?.token, 'lip_secret');
    expect(await pending.settle(), isNull);
  });

  test(
    'failed removal retries local deletion without revoking twice',
    () async {
      saved = someone();
      final state = owner();
      await state.load();
      writeFails = true;
      await state.logOut();
      writeFails = false;
      await state.retrySave();
      expect(login.revoked, ['lip_secret']);
      expect(saved, isNull);
      expect(await pending.settle(), isNull);
    },
  );

  test('logging out revokes the token and forgets the account', () async {
    saved = someone();
    final state = owner();
    await state.load();
    await state.logOut();
    expect(login.revoked, ['lip_secret']);
    expect(saved, isNull);
    expect(state.status, isA<SignedOut>());
  });

  test('logging out when the preferences will not forget still signs out, '
      'and says the account may be back next time', () async {
    saved = someone();
    final state = owner();
    await state.load();
    writeFails = true;
    await state.logOut();
    expect(state.status, isA<SignedOut>());
    expect(login.revoked, ['lip_secret']);
    expect(state.problem, contains('could not be removed'));
    expect(state.problem, contains('next time'));
  });

  test('every change notifies once', () async {
    final state = owner();
    await state.load();
    expect(notified, 1);
    final done = state.logIn();
    await Future<void>.delayed(Duration.zero);
    expect(notified, 3, reason: 'connecting, then the page');
    login.browserBack(loggedIn());
    await done;
    expect(notified, 4);
  });

  test('disposing ends a waiting login', () async {
    final state = LichessAccountState(
      login: login,
      read: () async => null,
      write: (_) async => true,
    );
    final done = state.logIn();
    await Future<void>.delayed(Duration.zero);
    state.dispose();
    await done;
    expect(login.waiting, isFalse);
  });
}

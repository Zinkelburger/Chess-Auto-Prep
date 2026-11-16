// What a Lichess sign-in answers: a token refused or a browser flow given
// up is not taken, a token tried while the browser flow waits is refused,
// and a flow just begun asks for no link yet.
import 'package:chess_auto_prep/features/settings/lichess_account.dart';
import 'package:chess_auto_prep/net/lichess_login.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_login.dart';

void main() {
  late ScriptedLogin login;

  LichessAccountState owner() {
    final state = LichessAccountState(
      login: login,
      read: () async => null,
      write: (account) async => true,
    );
    addTearDown(state.dispose);
    return state;
  }

  setUp(() => login = ScriptedLogin());

  test('a refused token is not taken', () async {
    expect(await owner().useToken('lip_wrong'), isFalse);
  });

  test('a token given up on is not taken', () async {
    login.tokenOutcome = const LoginCancelled();
    expect(await owner().useToken('lip_secret'), isFalse);
  });

  test('a sign-in whose save throws is not taken', () async {
    login.tokenOutcome = loggedIn(personal: true);
    final state = LichessAccountState(
      login: login,
      read: () async => null,
      write: (account) async {
        if (account != null) throw StateError('disk full');
        return true;
      },
    );
    addTearDown(state.dispose);
    expect(await state.useToken('lip_secret'), isFalse);
    expect(state.status, isA<SignedOut>());
  });

  test('a flow just begun asks for no link, and a token tried while it '
      'waits is refused', () async {
    final state = owner();
    final flow = state.logIn();
    expect((state.status as Connecting).browserOpened, isTrue);
    await pumpEventQueue();
    expect(await state.useToken('lip_secret'), isFalse);
    await state.cancel();
    await flow;
  });
}

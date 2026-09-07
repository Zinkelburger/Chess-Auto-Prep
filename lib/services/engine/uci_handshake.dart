import 'dart:async';

import 'engine_connection.dart';

/// Each handshake owns a subscription only until its reply, failure or timeout.
Future<void> performUciHandshake(
  EngineConnection connection, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  Future<void> exchange(String command, String reply) async {
    final ready = Completer<void>();
    void fail(Object error) {
      if (!ready.isCompleted) ready.completeError(error);
    }

    final subscription = connection.stdout.listen(
      (line) {
        if (line.trim() == reply && !ready.isCompleted) ready.complete();
      },
      onError: fail,
      onDone: () => fail(StateError('Engine closed during UCI handshake')),
    );
    try {
      connection.sendCommand(command);
      await ready.future.timeout(timeout);
    } finally {
      await subscription.cancel();
    }
  }

  await exchange('uci', 'uciok');
  await exchange('isready', 'readyok');
}

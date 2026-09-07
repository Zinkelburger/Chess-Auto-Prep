import 'dart:async';
import 'dart:isolate';

import 'package:chess_auto_prep/utils/isolate_task.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('transfers nullable results and forwards progress', () async {
    final progress = <Object?>[];
    final task = IsolateTask();
    expect(
      await task.run<int?>((port) {
        port.send([1, 2]);
        return null;
      }, onProgress: progress.add),
      isNull,
    );
    expect(progress, [
      [1, 2],
    ]);
    expect(await task.run((_) => 42), 42);
  });

  test(
    'uncaught failure and exit without a result complete promptly',
    () async {
      await expectLater(
        IsolateTask().run<int>((_) => throw StateError('broken')),
        throwsA(isA<RemoteError>()),
      );
      await expectLater(
        IsolateTask().run<int>((_) => Isolate.exit()),
        throwsStateError,
      );
    },
  );

  test(
    'cancels CPU work after progress and permits a replacement task',
    () async {
      final task = IsolateTask();
      final started = Completer<void>();
      final running = task.run<int>((port) {
        port.send(1);
        while (true) {} // cancellation must kill the isolate, not ignore a result
      }, onProgress: (_) => started.complete());
      final cancelled = expectLater(
        running,
        throwsA(isA<IsolateTaskCancelled>()),
      );
      await started.future;
      task.cancel();
      await cancelled;
      expect(await IsolateTask().run((_) => 7), 7);
    },
  );

  test(
    'cancellation during spawn settles and rejects subsequent work',
    () async {
      final task = IsolateTask();
      final running = task.run<int>((_) async {
        await Future<void>.delayed(const Duration(seconds: 30));
        return 1;
      });
      final cancelled = expectLater(
        running,
        throwsA(isA<IsolateTaskCancelled>()),
      );
      task.cancel();
      await cancelled;
      await expectLater(
        task.run((_) => 2),
        throwsA(isA<IsolateTaskCancelled>()),
      );
    },
  );

  test('timeout kills stalled work', () async {
    await expectLater(
      IsolateTask().run<int>((_) async {
        await Future<void>.delayed(const Duration(seconds: 30));
        return 0;
      }, timeout: const Duration(milliseconds: 50)),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('spawn failure cleans up so the owner can run again', () async {
    final port = ReceivePort();
    final task = IsolateTask();
    await expectLater(task.run((_) => port.hashCode), throwsArgumentError);
    port.close();
    expect(await task.run((_) => 3), 3);
  });
}

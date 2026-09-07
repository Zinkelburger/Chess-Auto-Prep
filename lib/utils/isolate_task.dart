import 'dart:async';
import 'dart:isolate';

class IsolateTaskCancelled implements Exception {
  const IsolateTaskCancelled();
}

/// A cancellable owner for background computation. Cancellation kills CPU work,
/// completes its awaiter, and also covers cancellation during Isolate.spawn.
/// Work may send progress to its port; the final object is transferred on exit.
/// Pass only sendable data in [work], never a widget/controller closure.
class IsolateTask {
  bool _cancelled = false;
  void Function()? _cancelRunning;
  bool get isCancelled => _cancelled;

  void cancel() {
    _cancelled = true;
    _cancelRunning?.call();
  }

  /// Use a top-level/static function and explicit data from UI callers. A
  /// closure declared beside a setState/progress callback can implicitly
  /// capture that callback's widget state as part of its shared context.
  Future<R> compute<R, A>(FutureOr<R> Function(A) work, A argument) =>
      run(_bindComputation(work, argument));

  Future<R> run<R>(
    FutureOr<R> Function(SendPort progress) work, {
    void Function(Object? message)? onProgress,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    if (_cancelled) throw const IsolateTaskCancelled();
    if (_cancelRunning != null) {
      throw StateError('Isolate task already running');
    }
    final port = ReceivePort();
    final result = Completer<R>();
    Isolate? isolate;
    void fail(Object error, [StackTrace? stack]) {
      if (!result.isCompleted) result.completeError(error, stack);
    }

    void cancel() {
      isolate?.kill(priority: Isolate.immediate);
      fail(const IsolateTaskCancelled());
    }

    _cancelRunning = cancel;
    final subscription = port.listen((message) {
      if (result.isCompleted) return;
      if (message is _Result<R>) {
        result.complete(message.value);
      } else if (message == null) {
        fail(StateError('Isolate exited without a result'));
      } else if (message is List &&
          message.length == 2 &&
          message[0] is String &&
          message[1] is String) {
        fail(RemoteError(message[0] as String, message[1] as String));
      } else {
        try {
          onProgress?.call(message);
        } catch (error, stack) {
          fail(error, stack);
        }
      }
    });
    final timer = Timer(
      timeout,
      () => fail(TimeoutException('Isolate task timed out', timeout)),
    );
    // Listen to completion before awaiting spawn: cancellation/errors during
    // startup must never surface as an unhandled asynchronous error.
    final completion = result.future;
    unawaited(
      completion.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    try {
      isolate = await Isolate.spawn(
        _run<R>,
        (work: work, port: port.sendPort),
        onError: port.sendPort,
        onExit: port.sendPort,
      );
      if (_cancelled) cancel();
      return await completion;
    } finally {
      timer.cancel();
      isolate?.kill(priority: Isolate.immediate);
      await subscription.cancel();
      port.close();
      _cancelRunning = null;
    }
  }
}

class _Result<R> {
  const _Result(this.value);
  final R value;
}

Future<void> _run<R>(
  ({FutureOr<R> Function(SendPort) work, SendPort port}) args,
) async {
  final value = await args.work(args.port);
  Isolate.exit(args.port, _Result<R>(value));
}

FutureOr<R> Function(SendPort) _bindComputation<R, A>(
  FutureOr<R> Function(A) work,
  A argument,
) =>
    (_) => work(argument);

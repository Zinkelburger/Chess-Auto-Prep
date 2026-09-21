import 'dart:async';

/// When a draft goes to the disk: the wait after the last edit, and what is
/// on its way once it is over.
///
/// An edit starts the wait, every edit inside it puts the whole of it back,
/// and the write goes out once when it runs out, with the newest text: a
/// burst of moves is one write, not a queue of stale snapshots. Anything
/// that needs the file now — opening another document, a rename, the window
/// closing — [flush]es, which ends the wait at once and answers when nothing
/// is on its way any more. This owns the timing; what is written, and what
/// the store's answer means, is the saver's.
final class SaveClock {
  SaveClock({required this.delay});

  /// How long the file waits after the last edit before it is written.
  final Duration delay;

  /// The clock a draft is waiting on, and the wait itself. Both are null
  /// when nothing is waiting.
  Timer? _timer;
  Completer<void>? _waiting;

  /// The write going out and everything that collapses behind it, so the
  /// app can wait for the file to hold the draft before it closes.
  Future<void>? _inFlight;

  /// Whether a draft is waiting for its second to run out.
  bool get isWaiting => _waiting != null;

  /// A draft was typed. [write] goes out when the wait is over; an edit
  /// while one is already waiting puts the whole wait back instead.
  void edited(Future<void> Function() write) {
    if (_waiting != null) {
      _restart();
      return;
    }
    waitsFor(_waitThenWrite(write));
  }

  /// [work] is what the file is waiting for now — a hold for a rename, or an
  /// undo — so a [flush] waits for the whole of it rather than for a write
  /// that finished before it began.
  ///
  /// What is kept here can only complete, never fail: work that throws is
  /// its caller's to handle, and a failed future left here would throw again
  /// at every later flush.
  void waitsFor<T>(Future<T> work) {
    _inFlight = work.then<void>((_) {}, onError: (Object _) {});
  }

  /// Ends the wait and answers when nothing is on its way any more: the
  /// write in flight, the one that collapsed behind it, and a hold that is
  /// keeping both waiting. A write that was refused or failed also ends it.
  Future<void> flush() {
    hurry();
    return _inFlight ?? Future<void>.value();
  }

  /// Ends the wait, if there is one, without waiting for what it starts.
  /// The wait is always ended rather than dropped: a flush is waiting on it.
  void hurry() {
    _timer?.cancel();
    _timer = null;
    final waiting = _waiting;
    _waiting = null;
    waiting?.complete();
  }

  Future<void> _waitThenWrite(Future<void> Function() write) async {
    final waiting = _waiting = Completer<void>();
    // No wait at all is no clock at all: the draft goes out on the next
    // turn, and nothing is left ticking for a test's widget tree to trip on.
    if (delay == Duration.zero) {
      hurry();
    } else {
      _restart();
    }
    await waiting.future;
    await write();
  }

  void _restart() {
    _timer?.cancel();
    _timer = Timer(delay, hurry);
  }
}

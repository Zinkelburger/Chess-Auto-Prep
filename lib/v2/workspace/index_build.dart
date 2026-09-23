import 'dart:async';
import 'dart:isolate';

import '../chess/opening_index.dart';
import '../chess/pgn/chapter.dart' show readOffThreadFrom;

/// One [OpeningIndex] being built, which can be stopped.
///
/// Games of fewer than [readOffThreadFrom] characters in all are indexed
/// at once, here: the trip to another isolate costs more than the work.
/// More are indexed on an isolate of their own, which reports how far it
/// has got and which [cancel] kills, so a file of ten thousand games the
/// user has already left stops using the machine at once rather than
/// finishing for nobody.
final class IndexBuild {
  IndexBuild._(this._done);

  /// Starts indexing [texts], named by [ids] (see [OpeningIndex.of]).
  /// [onProgress] hears how many games are done while it runs on another
  /// isolate.
  factory IndexBuild.start(
    List<String> texts, {
    List<String>? ids,
    void Function(int done)? onProgress,
  }) {
    final size = texts.fold(0, (n, text) => n + text.length);
    if (size < readOffThreadFrom) {
      final done = Completer<OpeningIndex?>()
        ..complete(OpeningIndex.of(texts, ids: ids));
      return IndexBuild._(done);
    }
    final build = IndexBuild._(Completer<OpeningIndex?>());
    unawaited(build._spawn(texts, ids, onProgress));
    return build;
  }

  final Completer<OpeningIndex?> _done;
  final _port = ReceivePort();
  Isolate? _isolate;
  bool _cancelled = false;

  /// The index, or null when the build was cancelled. Fails with what went
  /// wrong when indexing threw.
  Future<OpeningIndex?> get result => _done.future;

  /// Stops the build; [result] answers null if it had not finished.
  void cancel() {
    _cancelled = true;
    _isolate?.kill(priority: Isolate.immediate);
    _finish(null);
  }

  Future<void> _spawn(
    List<String> texts,
    List<String>? ids,
    void Function(int done)? onProgress,
  ) async {
    _port.listen((message) {
      switch (message) {
        case int done:
          onProgress?.call(done);
        case OpeningIndex index:
          _finish(index);
        case [Object error, Object? stack]:
          _fail(error, stack);
        default:
          // The isolate went without a word: killed, or out of memory.
          if (!_done.isCompleted) _fail('the indexing stopped', null);
      }
    });
    try {
      final isolate = await Isolate.spawn(
        _index,
        (_port.sendPort, texts, ids),
        onError: _port.sendPort,
        onExit: _port.sendPort,
        debugName: 'opening index',
      );
      _isolate = isolate;
      if (_cancelled) isolate.kill(priority: Isolate.immediate);
    } on Object catch (error, stack) {
      _fail(error, stack);
    }
  }

  void _finish(OpeningIndex? index) {
    _port.close();
    if (!_done.isCompleted) _done.complete(index);
  }

  void _fail(Object error, Object? stack) {
    _port.close();
    if (_done.isCompleted) return;
    _done.completeError(
      error,
      stack is StackTrace ? stack : StackTrace.fromString('$stack'),
    );
  }
}

/// The isolate's work: the index, sent back without a copy as it exits.
void _index((SendPort, List<String>, List<String>?) job) {
  final (port, texts, ids) = job;
  final index = OpeningIndex.of(texts, ids: ids, onProgress: port.send);
  Isolate.exit(port, index);
}

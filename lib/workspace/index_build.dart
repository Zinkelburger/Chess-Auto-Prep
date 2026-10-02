import 'dart:async';
import 'dart:isolate';

import '../chess/opening_index.dart';
import '../chess/pgn/chapter.dart' show movesBeingRead, readOffThreadFrom;
import '../chess/pgn/chapter_line.dart';

/// One [OpeningIndex] being built, which can be stopped.
///
/// Games of fewer than [readOffThreadFrom] characters in all are indexed
/// at once, here: the trip to another isolate costs more than the work.
/// More, given as text ([IndexBuild.start]), are read and indexed on an
/// isolate of their own, which reports how far it has got and which
/// [cancel] kills, so a file of ten thousand games the user has already
/// left stops using the machine at once rather than finishing for nobody.
/// More, given already read ([IndexBuild.ofLines]), are indexed here a
/// turn at a time, with the screen and the keys served between turns:
/// walking a tree in hand costs a small part of reading its text again,
/// and less than copying the trees to another isolate would.
final class IndexBuild {
  IndexBuild._(this._done);

  /// Starts indexing [lines], the games of an open file, from the trees
  /// they were read into. [onProgress] hears how many games are done after
  /// each turn but the last.
  factory IndexBuild.ofLines(
    List<ChapterLine> lines, {
    void Function(int done)? onProgress,
  }) {
    final build = IndexBuild._(Completer<OpeningIndex?>());
    final size = lines.fold(0, (n, line) => n + line.text.length);
    final index = OpeningIndexBuilder();
    if (size < readOffThreadFrom) {
      build._guarded(() {
        lines.forEach(index.addLine);
        build._finish(index.build());
      });
    } else if (movesBeingRead(lines) case final read?) {
      // The games' moves are on their way from the isolate reading them:
      // walking them now would read each one here instead.
      unawaited(
        read.whenComplete(() {
          if (!build._done.isCompleted) {
            build._nextTurn(lines, index, 0, onProgress);
          }
        }),
      );
    } else {
      build._nextTurn(lines, index, 0, onProgress);
    }
    return build;
  }

  /// How long one turn of [IndexBuild.ofLines] works before the event loop
  /// gets its own: a quarter of a frame.
  static const turn = Duration(milliseconds: 4);

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
      final done = Completer<OpeningIndex?>();
      try {
        done.complete(OpeningIndex.of(texts, ids: ids));
      } on Object catch (error, stack) {
        done.completeError(error, stack);
      }
      return IndexBuild._(done);
    }
    final build = IndexBuild._(Completer<OpeningIndex?>());
    unawaited(build._spawn(texts, ids, onProgress));
    return build;
  }

  final Completer<OpeningIndex?> _done;
  ReceivePort? _port;
  Isolate? _isolate;
  Timer? _turn;

  /// The index, or null when the build was cancelled. Fails with what went
  /// wrong when indexing threw.
  Future<OpeningIndex?> get result => _done.future;

  /// Stops the build; [result] answers null if it had not finished.
  void cancel() => _finish(null);

  /// Indexes [lines] from [done] on for one [turn], or for
  /// [OpeningIndex.progressEvery] games if that is sooner, once the event
  /// loop has had its own.
  void _nextTurn(
    List<ChapterLine> lines,
    OpeningIndexBuilder index,
    int done,
    void Function(int done)? onProgress,
  ) {
    void work() {
      final clock = Stopwatch()..start();
      final stop = done + OpeningIndex.progressEvery;
      while (done < lines.length && done < stop && clock.elapsed < turn) {
        index.addLine(lines[done++]);
      }
      if (done == lines.length) {
        _finish(index.build());
      } else {
        onProgress?.call(done);
        if (!_done.isCompleted) _nextTurn(lines, index, done, onProgress);
      }
    }

    _turn = Timer(Duration.zero, () => _guarded(work));
  }

  void _guarded(void Function() work) {
    if (_done.isCompleted) return;
    try {
      work();
    } on Object catch (error, stack) {
      _fail(error, stack);
    }
  }

  Future<void> _spawn(
    List<String> texts,
    List<String>? ids,
    void Function(int done)? onProgress,
  ) async {
    final port = _port = ReceivePort();
    port.listen(
      (message) => _guarded(() {
        switch (message) {
          case int done:
            onProgress?.call(done);
          case OpeningIndex index:
            _finish(index);
          case [Object error, Object? stack]:
            _fail(error, stack);
          default:
            // The isolate went without a word: killed, or out of memory.
            _fail(
              StateError('The indexing worker exited without an answer.'),
              null,
            );
        }
      }),
    );
    try {
      final isolate = await Isolate.spawn(
        _index,
        (port.sendPort, texts, ids),
        onError: port.sendPort,
        onExit: port.sendPort,
        debugName: 'opening index',
      );
      _isolate = isolate;
      // Completion can win the race with spawn, including a progress
      // callback that cancels or fails before we receive the handle.
      if (_done.isCompleted) isolate.kill(priority: Isolate.immediate);
    } on Object catch (error, stack) {
      _fail(error, stack);
    }
  }

  void _finish(OpeningIndex? index) {
    if (_done.isCompleted) return;
    _close();
    _done.complete(index);
  }

  void _fail(Object error, Object? stack) {
    if (_done.isCompleted) return;
    _close();
    _done.completeError(
      error,
      stack is StackTrace ? stack : StackTrace.fromString('$stack'),
    );
  }

  /// Success, failure and cancellation all end the same lifetime. The
  /// completer is the terminal-state flag; no separate cancellation state
  /// can drift away from what callers observe through [result].
  void _close() {
    _turn?.cancel();
    _port?.close();
    _isolate?.kill(priority: Isolate.immediate);
  }
}

/// The isolate's work: the index, sent back without a copy as it exits.
void _index((SendPort, List<String>, List<String>?) job) {
  final (port, texts, ids) = job;
  final index = OpeningIndex.of(texts, ids: ids, onProgress: port.send);
  Isolate.exit(port, index);
}

extension on OpeningIndexBuilder {
  void addLine(ChapterLine line) =>
      add(tags: line.tags, tree: line.tree, terminator: line.terminator);
}

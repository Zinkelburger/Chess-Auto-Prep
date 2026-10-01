import 'dart:async';
import 'dart:isolate';

import '../chess/game_filter.dart';
import '../chess/move_sequence.dart';
import '../chess/pgn/game_text.dart';
import '../chess/pgn/game_tree.dart';

/// A filter over one immutable header snapshot. Regex evaluation must never
/// run on the UI isolate: even a short header can cause exponential work.
/// Cancellation and the deadline kill the isolate, including one still being
/// spawned.
///
/// The move trees do not cross the boundary. Sending them copies every move
/// of every game, here, before the isolate starts: most of a second for ten
/// thousand games, with the window held, and the file's moves in memory
/// twice. What a filter reads of a game's moves is small — whether its main
/// line reaches a position, and the moves of that line as text — so that is
/// taken from the trees on this isolate, a turn at a time ([turn]), and only
/// that is sent.
final class FilterRun {
  FilterRun.start(
    List<List<PgnHeader>> headers,
    GameFilter filter, {
    Duration timeout = const Duration(seconds: 2),
    List<GameTree?>? trees,
  }) {
    _timer = Timer(timeout, () {
      _fail(TimeoutException('Filtering exceeded its time limit.'));
    });
    unawaited(_run(headers, filter, trees));
  }

  /// How long the trees are read before the event loop gets its own: a
  /// quarter of a frame.
  static const turn = Duration(milliseconds: 4);

  final _done = Completer<List<bool>?>();
  ReceivePort? _port;
  Isolate? _isolate;
  Timer? _timer;

  /// Null means cancelled; failures, including timeout, complete with error.
  Future<List<bool>?> get result => _done.future;

  void cancel() {
    if (_done.isCompleted) return;
    _close();
    _done.complete(null);
  }

  Future<void> _run(
    List<List<PgnHeader>> headers,
    GameFilter filter,
    List<GameTree?>? trees,
  ) async {
    final _MovesRead moves;
    try {
      moves = await _movesRead(headers.length, filter, trees);
    } on Object catch (error, stack) {
      return _fail(error, stack);
    }
    if (_done.isCompleted) return;
    await _spawn(headers, filter, moves);
  }

  /// What [filter] reads of each game's moves, for as many games as there
  /// are headers. A filter given no trees finds no position and no moves.
  Future<_MovesRead> _movesRead(
    int games,
    GameFilter filter,
    List<GameTree?>? trees,
  ) async {
    final position = filter.position;
    final reaches = position == null ? null : List.filled(games, false);
    final sans = filter.readsMoves
        ? List<List<String>>.filled(games, const [])
        : null;
    if (trees == null || (reaches == null && sans == null)) {
      return (reaches: reaches, sans: sans);
    }
    final clock = Stopwatch()..start();
    for (final (index, tree) in trees.indexed) {
      if (clock.elapsed >= turn) {
        await Future<void>.delayed(Duration.zero);
        if (_done.isCompleted) break;
        clock.reset();
      }
      if (position != null)
        reaches?[index] = tree?.mainLineTo(position) != null;
      sans?[index] = mainLineSans(tree);
    }
    return (reaches: reaches, sans: sans);
  }

  Future<void> _spawn(
    List<List<PgnHeader>> headers,
    GameFilter filter,
    _MovesRead moves,
  ) async {
    final port = _port = ReceivePort();
    port.listen((message) {
      switch (message) {
        case List<bool> passes:
          _close();
          if (!_done.isCompleted) _done.complete(passes);
        case [Object error, Object? stack]:
          _fail(StateError('$error\n$stack'));
        default:
          _fail(StateError('The filter worker exited without an answer.'));
      }
    });
    try {
      final isolate = await Isolate.spawn(
        _filterHeaders,
        (port.sendPort, headers, filter, moves),
        onError: port.sendPort,
        onExit: port.sendPort,
        debugName: 'PGN filter',
      );
      _isolate = isolate;
      if (_done.isCompleted) isolate.kill(priority: Isolate.immediate);
    } on Object catch (error, stack) {
      _fail(error, stack);
    }
  }

  void _fail(Object error, [StackTrace? stack]) {
    if (_done.isCompleted) return;
    _close();
    _done.completeError(error, stack);
  }

  void _close() {
    _timer?.cancel();
    _port?.close();
    _isolate?.kill(priority: Isolate.immediate);
  }
}

/// What a filter reads of the games' moves: whether each game's main line
/// reaches the filter's position, and each main line as the filter compares
/// moves. Either is null when the filter does not ask.
typedef _MovesRead = ({List<bool>? reaches, List<List<String>>? sans});

void _filterHeaders(
  (SendPort, List<List<PgnHeader>>, GameFilter, _MovesRead) job,
) {
  final (port, headers, filter, moves) = job;
  Isolate.exit(port, [
    for (final (index, tags) in headers.indexed)
      filter.keeps((name) => tagValue(tags, name), moves: moves.sans?[index]) &&
          (moves.reaches?[index] ?? true),
  ]);
}

/// [tree]'s main line as the filter compares moves; empty for a game that
/// could not be read.
List<String> mainLineSans(GameTree? tree) => [
  for (final node in tree?.mainLine ?? const <MoveNode>[]) normalSan(node.san),
];

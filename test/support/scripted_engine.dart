/// A scripted Stockfish stand-in for services that talk to [StockfishPool].
///
/// The hole hunt, the trick hunt and the engine-weakness finder all reach the
/// engine through `StockfishPool.instance`, so a unit test drives them by
/// injecting an [EvalWorker] built on one of these ([StockfishPool
/// .addWorkerForTest]) instead of spawning a real binary.
///
/// It speaks just enough UCI for [EvalWorker]: `isready` → `readyok`, and a
/// `go` answered with the script registered for the position last sent by
/// `position fen …`.
///
/// **Scores are side-to-move relative, exactly as Stockfish reports them.**
/// That is the point of the double: `runDiscovery` White-normalises using the
/// `isWhiteToMove` flag its *caller* passes, so a service that passes the
/// wrong flag flips the sign of everything downstream — and a script written
/// in White-relative cp would hide it.
library;

import 'dart:async';

import 'package:chess_auto_prep/services/engine/engine_connection.dart';
import 'package:chess_auto_prep/utils/fen_utils.dart';

/// One scripted engine line: a score (side-to-move relative) and a PV.
class ScriptLine {
  /// Centipawns, side-to-move relative. Null when [mate] is set.
  final int? cp;

  /// Mate distance, side-to-move relative (positive = side to move mates).
  final int? mate;

  /// Principal variation in UCI. The first move is the line's move.
  final List<String> pv;

  final int depth;

  const ScriptLine.cp(int this.cp, {this.pv = const [], this.depth = 20})
    : mate = null;

  const ScriptLine.mate(int this.mate, {this.pv = const [], this.depth = 20})
    : cp = null;

  String _score() => mate != null ? 'mate $mate' : 'cp $cp';

  String infoLine({int? pvNumber}) {
    final multipv = pvNumber == null ? '' : ' multipv $pvNumber';
    final line = pv.isEmpty ? '' : ' pv ${pv.join(' ')}';
    return 'info depth $depth$multipv score ${_score()} nodes 4242 nps 4242'
        '$line';
  }
}

class ScriptedEngine implements EngineConnection {
  final _stdout = StreamController<String>.broadcast();
  final _done = Completer<void>();

  /// MultiPV script per position, keyed by [normalizeFen]. Best line first —
  /// the order Stockfish reports and the services rely on.
  final Map<String, List<ScriptLine>> discovery = {};

  /// Single-PV script per position, keyed by [normalizeFen].
  final Map<String, ScriptLine> evals = {};

  /// Every UCI command the worker sent, in order.
  final List<String> commands = [];

  /// Positions handed to a MultiPV search, in order (full FENs).
  final List<String> discoverySearches = [];

  /// Positions handed to a single-PV search, in order (full FENs).
  final List<String> evalSearches = [];

  /// Called once a search has been launched on [fen], before the scripted
  /// answer arrives. Tests use it to abort the search (`worker.stop()`) the
  /// way a cancel does in production.
  ///
  /// It runs on a microtask rather than inside `sendCommand`, because a real
  /// engine cannot call back into the worker mid-`sendCommand`: doing so
  /// re-enters `evaluateFen` between its `go` and its `return completer
  /// .future`, and the completer `stop()` just cleared is gone by the time
  /// that line runs.
  void Function(String fen)? onGo;

  bool disposed = false;

  int _multiPv = 1;
  String _fen = '';

  @override
  Stream<String> get stdout => _stdout.stream;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> waitForReady() async {}

  @override
  void sendCommand(String command) {
    commands.add(command);

    if (command == 'isready') {
      scheduleMicrotask(() {
        if (!_stdout.isClosed) _stdout.add('readyok');
      });
      return;
    }
    if (command.startsWith('setoption name MultiPV value ')) {
      _multiPv = int.tryParse(command.split(' ').last) ?? 1;
      return;
    }
    if (command.startsWith('position fen ')) {
      _fen = command.substring('position fen '.length).trim();
      return;
    }
    if (!command.startsWith('go ')) return;

    // A MultiPV setting above 1 is what distinguishes a discovery search from
    // a plain eval: `runDiscovery` sets it before searching and resets it to
    // 1 afterwards, and `evaluateFen` never touches it.
    final isDiscovery = _multiPv > 1;
    final fen = _fen;
    (isDiscovery ? discoverySearches : evalSearches).add(fen);
    final hook = onGo;
    if (hook != null) scheduleMicrotask(() => hook(fen));

    final key = normalizeFen(fen);
    scheduleMicrotask(() {
      if (_stdout.isClosed) return;
      if (isDiscovery) {
        final lines = discovery[key] ?? const <ScriptLine>[];
        for (var i = 0; i < lines.length; i++) {
          _stdout.add(lines[i].infoLine(pvNumber: i + 1));
        }
        _stdout.add(_bestmove(lines.isEmpty ? null : lines.first));
      } else {
        final line = evals[key];
        if (line != null) _stdout.add(line.infoLine());
        _stdout.add(_bestmove(line));
      }
    });
  }

  static String _bestmove(ScriptLine? line) => line == null || line.pv.isEmpty
      ? 'bestmove (none)'
      : 'bestmove ${line.pv.first}';

  /// Kill the engine process the way an unexpected exit does.
  void crash() {
    if (!_done.isCompleted) _done.complete();
    if (!_stdout.isClosed) {
      _stdout.addError(StateError('Stockfish process exited (1)'));
    }
  }

  @override
  void dispose() {
    disposed = true;
    unawaited(_stdout.close());
  }
}

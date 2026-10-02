import 'dart:async';
import 'dart:math' as math;

import '../chess/bughouse/table.dart';
import 'engine.dart';
import 'uci_process.dart';

/// CrazyAra OS-96 v1.0 root priors, with FICS-fitted temperature 1.5.
/// The diagnostic Policy column is used, never search visits or bestmove.
final class CrazyaraProcess implements EngineProcess {
  CrazyaraProcess._(this._process) {
    _process.lines.listen(_line, onDone: _gone);
  }

  static Future<CrazyaraProcess> start(UciProcess process) async {
    final engine = CrazyaraProcess._(process);
    try {
      await engine._command(['uci'], 'uciok');
      final options = {
        'Threads': '1',
        'Threads_NN_Inference': '2',
        'Batch_Size': '1',
        'Use_Raw_Network': 'false',
        'Reuse_Tree': 'false',
        'Temperature_Moves': '0',
        'Centi_Temperature': '0',
        'Centi_Node_Temperature': '100',
        'Centi_Dirichlet_Epsilon': '0',
        'Centi_Epsilon_Checks': '0',
        'Centi_Epsilon_Greedy': '0',
        'Centi_Quantile_Clipping': '0',
      };
      await engine._command(
        [
          for (final entry in options.entries)
            'setoption name ${entry.key} value ${entry.value}',
          'isready',
        ],
        'readyok',
        patience: const Duration(seconds: 90),
      );
      return engine;
    } on Object {
      await process.kill();
      rethrow;
    }
  }

  final UciProcess _process;
  final _exit = Completer<EngineExit>();
  Completer<List<String>>? _answer;
  String _until = '';
  final _lines = <String>[];
  Future<void> _queue = Future.value();

  @override
  int get pid => _process.pid;
  @override
  Future<EngineExit> get exited => _exit.future;

  Future<List<String>> _command(
    List<String> commands,
    String until, {
    Duration patience = const Duration(seconds: 30),
  }) async {
    if (_exit.isCompleted) throw const EngineFailure('CrazyAra stopped.');
    final done = _answer = Completer<List<String>>();
    _until = until;
    _lines.clear();
    for (final command in commands) {
      _process.send(command);
    }
    try {
      return await done.future.timeout(patience);
    } on TimeoutException {
      await _process.kill();
      throw const EngineFailure('CrazyAra stopped answering.');
    } finally {
      _answer = null;
    }
  }

  Future<Map<String, double>> policy(
    TablePosition position,
    BoardNumber board,
  ) {
    final answer = _queue.then((_) => _policy(position, board));
    _queue = answer.then((_) {}, onError: (Object _) {});
    return answer;
  }

  Future<Map<String, double>> _policy(
    TablePosition position,
    BoardNumber board,
  ) async {
    final legal = position.legalMoves(board);
    if (legal.isEmpty) return {};
    if (legal.length == 1) return {legal.single.uci: 1};
    await _command([
      'ucinewgame',
      'position fen ${position.board(board).fen}',
      'go nodes 1',
    ], 'bestmove ');
    final lines = await _command(['root', 'isready'], 'readyok');
    return readCrazyaraPolicy(position, board, lines);
  }

  void _line(String line) {
    if (_answer == null) return;
    _lines.add(line);
    if (line.trim().startsWith(_until)) {
      _answer!.complete(List.of(_lines));
      _answer = null;
    }
  }

  void _gone() {
    _answer?.completeError(const EngineFailure('CrazyAra stopped.'));
    _answer = null;
    if (!_exit.isCompleted) _exit.complete(EngineExit.ended);
  }

  @override
  Future<void> quit() async {
    if (_exit.isCompleted) return;
    _process.send('stop');
    _process.send('quit');
    await exited.timeout(
      const Duration(seconds: 3),
      onTimeout: () async {
        await _process.kill();
        return EngineExit.unresponsive;
      },
    );
  }
}

Map<String, double> readCrazyaraPolicy(
  TablePosition position,
  BoardNumber board,
  List<String> lines,
) {
  final weights = <String, double>{};
  String bare(String san) => san.replaceAll(RegExp('[+#!?]'), '');
  final bySan = {for (final m in position.legalMoves(board)) bare(m.san): m};
  for (final line in lines) {
    if (!RegExp(r'^\s*\d+\s*\|').hasMatch(line)) continue;
    final fields = line.split('|');
    if (fields.length < 4)
      throw const EngineFailure('Incomplete CrazyAra policy.');
    final move = bySan[bare(fields[1].trim())];
    final raw = double.tryParse(fields[3].trim());
    if (move == null ||
        raw == null ||
        !raw.isFinite ||
        raw < 0 ||
        raw > 1 ||
        weights.containsKey(move.uci)) {
      throw const EngineFailure('Invalid CrazyAra policy.');
    }
    weights[move.uci] = raw;
  }
  final legal = position.legalMoves(board);
  final total = weights.values.fold(0.0, (a, b) => a + b);
  if (weights.length != legal.length || total <= 0 || total > 1.001) {
    throw const EngineFailure('CrazyAra did not score every legal move.');
  }
  final softened = {
    for (final entry in weights.entries)
      entry.key: math
          .pow(math.max(entry.value / total, 1e-8), 1 / 1.5)
          .toDouble(),
  };
  final sum = softened.values.fold(0.0, (a, b) => a + b);
  return {for (final entry in softened.entries) entry.key: entry.value / sum};
}

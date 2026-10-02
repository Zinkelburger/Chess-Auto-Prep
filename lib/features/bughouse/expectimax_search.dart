import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../chess/bughouse/expectimax.dart';
import '../../chess/bughouse/table.dart';
import '../../engines/bughouse_backend.dart';
import 'bughouse_lab.dart';

/// Owns a cancellable search snapshot. Board edits invalidate its rows; flips,
/// hover and the old engine panel's clock selector do not affect this model.
final class BughouseExpectimaxSearch extends ChangeNotifier {
  BughouseExpectimaxSearch({required this.lab, required this.startBackend}) {
    _position = lab.position.keyText;
    lab.addListener(_changed);
  }

  final BughouseLab lab;
  final Future<BughouseBackend> Function() startBackend;
  String _position = '';
  BoardNumber board = BoardNumber.one;
  int plies = 2;
  int maxReplies = 24;
  int coveragePercent = 90;
  bool running = false;
  bool complete = false;
  bool _disposed = false;
  int _generation = 0;
  int positions = 0;
  int total = 0;
  double minimumCoverage = 1;
  String? problem;
  String status = 'Search the position for practical chances.';
  List<BughouseBranch> rows = const [];
  BughouseBranch? selected;
  BughouseBackend? _backend;
  Future<void> _work = Future.value();

  Team get team => lab.position.mover(board).team;

  void configure({
    BoardNumber? board,
    int? plies,
    int? maxReplies,
    int? coverage,
  }) {
    if (running) return;
    this.board = board ?? this.board;
    this.plies = plies ?? this.plies;
    this.maxReplies = maxReplies ?? this.maxReplies;
    coveragePercent = coverage ?? coveragePercent;
    _clear();
    _notify();
  }

  void select(BughouseBranch row) {
    selected = row;
    lab.preview.value = {board: row.move.uci};
    _notify();
  }

  void _changed() {
    final position = lab.position.keyText;
    if (position == _position) return;
    _position = position;
    stop();
    _clear();
    _notify();
  }

  void _clear() {
    rows = const [];
    selected = null;
    problem = null;
    complete = false;
    positions = 0;
    total = 0;
    minimumCoverage = 1;
    status = 'Search the position for practical chances.';
  }

  Future<void> start() {
    if (running || _disposed) return _work;
    final before = _work;
    final generation = ++_generation;
    final root = lab.position;
    final chosenBoard = board;
    final options = BughouseSearchOptions(
      plies: plies,
      maxReplies: maxReplies,
      replyCoverage: coveragePercent / 100,
    );
    _clear();
    running = true;
    total = root.legalMoves(chosenBoard).length;
    status = 'Starting engines…';
    _notify();
    return _work = _run(before, generation, root, chosenBoard, options);
  }

  Future<void> _run(
    Future<void> before,
    int generation,
    TablePosition root,
    BoardNumber chosenBoard,
    BughouseSearchOptions options,
  ) async {
    bool current() => !_disposed && generation == _generation;
    BughouseBackend? backend;
    try {
      await before;
      if (!current()) return;
      backend = await startBackend();
      if (!current()) return;
      _backend = backend;
      final search = BughouseExpectimax(
        board: chosenBoard,
        team: root.mover(chosenBoard).team,
        policy: backend.policy,
        evaluate: backend.evaluate,
        options: options,
        cancelled: () => !current(),
        onProgress: (count) {
          if (!current()) return;
          positions = count;
          if (count % 32 == 0) {
            status = '${rows.length} / $total moves · $positions positions';
            _notify();
          }
        },
      );
      await for (final row in search.search(root)) {
        if (!current()) break;
        rows = [...rows, row]
          ..sort((a, b) => b.child.expected.compareTo(a.child.expected));
        positions = search.positions;
        minimumCoverage = search.minimumCoverage;
        status = '${rows.length} / $total moves · $positions positions';
        _notify();
      }
      if (current()) {
        complete = true;
        status = rows.isEmpty
            ? 'No moves to search: the position has ended.'
            : 'Complete · ${rows.length} moves · $positions positions';
        selected = rows.firstOrNull;
      }
    } on BughouseSearchStopped catch (e) {
      if (current()) status = '${e.reason} · ${rows.length} / $total moves';
    } on Object catch (e) {
      if (current()) {
        problem = '$e';
        status = 'Search failed';
      }
    } finally {
      await backend?.close();
      if (identical(_backend, backend)) _backend = null;
      if (current()) {
        running = false;
        _notify();
      }
    }
  }

  /// Releases native engines immediately; completed rows stay visibly partial.
  void stop() {
    if (!running) return;
    _generation++;
    running = false;
    status = 'Stopped · ${rows.length} / $total moves';
    final backend = _backend;
    _backend = null;
    if (backend != null) unawaited(backend.close());
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    lab.removeListener(_changed);
    super.dispose();
  }
}

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../chess/bughouse/expectimax.dart';
import '../../storage/bughouse_expectimax.dart';
import 'package:dartchess/dartchess.dart' show Side;
import '../../chess/bughouse/table.dart';
import '../../engines/bughouse_backend.dart';
import 'bughouse_lab.dart';

/// Owns a cancellable search snapshot. Board edits invalidate its rows; flips,
/// hover and the old engine panel's clock selector do not affect this model.
final class BughouseExpectimaxSearch extends ChangeNotifier {
  BughouseExpectimaxSearch({
    required this.lab,
    required this.startBackend,
    this.book,
  }) {
    _position = lab.position.keyText;
    lab.addListener(_changed);
    unawaited(_loadSaved());
  }

  final BughouseLab lab;
  final Future<BughouseBackend> Function(int nodes) startBackend;
  final BughouseExpectimaxBook? book;
  String _position = '';
  BoardNumber board = BoardNumber.one;
  int plies = 2;
  int nodes = 800;
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

  void configure({BoardNumber? board, int? plies, int? nodes}) {
    if (running) return;
    this.board = board ?? this.board;
    this.plies = plies ?? this.plies;
    this.nodes = nodes ?? this.nodes;
    _clear();
    unawaited(_loadSaved());
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
    unawaited(_loadSaved());
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

  Future<void> _loadSaved() async {
    if (book == null || _disposed || running) return;
    final generation = ++_generation;
    try {
      final saved = await book!.load(
        lab.position,
        board,
        BughouseSearchOptions(plies: plies, nodes: nodes),
      );
      if (_disposed || generation != _generation || saved == null) return;
      rows = [...saved]
        ..sort(
          (a, b) => lab.position.turn(board) == Side.white
              ? b.child.white.compareTo(a.child.white)
              : a.child.black.compareTo(b.child.black),
        );
      total = saved.length;
      complete = true;
      selected = rows.firstOrNull;
      status = 'Saved · ${rows.length} moves · both colours';
      _notify();
    } on Object catch (error) {
      if (_disposed || generation != _generation) return;
      problem = 'Could not read saved expectimax: $error';
      _notify();
    }
  }

  Future<void> start() {
    if (running || _disposed) return _work;
    final before = _work;
    final generation = ++_generation;
    final root = lab.position;
    final chosenBoard = board;
    final options = BughouseSearchOptions(plies: plies, nodes: nodes);
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
      final saved = await book?.load(root, chosenBoard, options);
      if (!current()) return;
      if (saved != null) {
        rows = [...saved]
          ..sort(
            (a, b) => lab.position.turn(board) == Side.white
                ? b.child.white.compareTo(a.child.white)
                : a.child.black.compareTo(b.child.black),
          );
        total = saved.length;
        complete = true;
        selected = rows.firstOrNull;
        status = 'Saved · ${rows.length} moves · both colours';
        return;
      }
      backend = await startBackend(options.nodes);
      if (!current()) return;
      _backend = backend;
      final search = BughouseExpectimax(
        board: chosenBoard,
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
          ..sort(
            (a, b) => root.turn(chosenBoard) == Side.white
                ? b.child.white.compareTo(a.child.white)
                : a.child.black.compareTo(b.child.black),
          );
        total = search.rootCandidates;
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
        await book?.save(root, chosenBoard, options, rows);
      }
    } on BughouseSearchStopped catch (e) {
      if (current()) status = '${e.reason} · ${rows.length} / $total moves';
    } on Object catch (e) {
      if (current()) {
        complete = false;
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

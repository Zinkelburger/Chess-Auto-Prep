/// The ordered queue of puzzles a practice session walks through.
library;

import 'dart:math';

import '../models/tactics_position.dart';
import '../models/tactics_session_settings.dart';

/// Indices into a database's position list, filtered and ordered for one
/// session, plus the cursor walking them.
///
/// The queue never wraps: [next] reports exhaustion at the last slot and
/// [previous] stops at the first. [currentPositionIndex] is only moved by
/// [start], [startWith], [next] and [previous] — removing a slot leaves it
/// where it was until the next navigation.
class TacticsSessionQueue {
  List<int> _slots = [];
  int _cursor = 0;

  /// Furthest slot reached this session (the "head"). Navigating back with
  /// [previous] doesn't lower it, so `_cursor < _head` means the user is
  /// reviewing an already-seen puzzle.
  int _head = 0;

  /// Index into the database's position list of the puzzle the cursor sits
  /// on; 0 when the queue is empty.
  int currentPositionIndex = 0;

  int get length => _slots.length;
  bool get isEmpty => _slots.isEmpty;

  /// Current 0-based slot within the queue.
  int get cursor => _cursor;

  /// True while the user has navigated back below the session head — i.e.
  /// the shown puzzle was already completed or skipped this session.
  bool get isViewingPast => _slots.isNotEmpty && _cursor < _head;

  /// Queue every position in [positions] that [settings] accepts, ordered
  /// per [TacticsSessionSettings.order] and, when
  /// [TacticsSessionSettings.groupByGame] is on, with each game's positions
  /// kept together in the order they occurred.
  void start(List<TacticsPosition> positions, TacticsSessionSettings settings) {
    _slots = [
      for (var i = 0; i < positions.length; i++)
        if (settings.accepts(positions[i])) i,
    ];
    _order(positions, settings.order);
    if (settings.groupByGame) _groupByGame(positions);
    _rewind();
  }

  /// Queue exactly [subset], in the given order — e.g. "Retry mistakes" from
  /// the session recap. Positions are matched by FEN against [positions];
  /// unknown FENs and repeats are skipped.
  void startWith(
    List<TacticsPosition> positions,
    List<TacticsPosition> subset,
  ) {
    _slots = <int>[];
    for (final wanted in subset) {
      final index = positions.indexWhere((p) => p.fen == wanted.fen);
      if (index != -1 && !_slots.contains(index)) _slots.add(index);
    }
    _rewind();
  }

  /// Drop the queue (a set switch, an external review closing).
  void clear() {
    _slots = [];
    _cursor = 0;
    _head = 0;
  }

  void _rewind() {
    _cursor = 0;
    _head = 0;
    currentPositionIndex = _slots.isNotEmpty ? _slots.first : 0;
  }

  void _order(List<TacticsPosition> positions, TacticsSessionOrder order) {
    switch (order) {
      case TacticsSessionOrder.newestFirst:
        _slots.sort(
          (a, b) => positions[b].gameDate.compareTo(positions[a].gameDate),
        );
      case TacticsSessionOrder.leastReviewed:
        _slots.sort(
          (a, b) =>
              positions[a].reviewCount.compareTo(positions[b].reviewCount),
        );
      case TacticsSessionOrder.worstSuccessRate:
        _slots.sort(
          (a, b) =>
              positions[a].successRate.compareTo(positions[b].successRate),
        );
      case TacticsSessionOrder.random:
        _slots.shuffle(Random());
    }
  }

  /// Keep each game's positions together, in the order they occurred. The
  /// ordering already applied still decides which game comes first (via the
  /// game's first position in that order).
  void _groupByGame(List<TacticsPosition> positions) {
    final gameRank = <String, int>{};
    for (final index in _slots) {
      gameRank.putIfAbsent(positions[index].gameId, () => gameRank.length);
    }
    _slots.sort((a, b) {
      final rankA = gameRank[positions[a].gameId]!;
      final rankB = gameRank[positions[b].gameId]!;
      if (rankA != rankB) return rankA.compareTo(rankB);
      return positions[a].moveNumber.compareTo(positions[b].moveNumber);
    });
  }

  /// Remove the slot holding [positionIndex] from the live queue, keeping
  /// the cursor and head on the same puzzles where possible.
  void remove(int positionIndex) {
    final slot = _slots.indexOf(positionIndex);
    if (slot == -1) return;
    _slots.removeAt(slot);
    if (slot < _cursor) {
      _cursor--;
    } else if (_cursor >= _slots.length && _slots.isNotEmpty) {
      _cursor = _slots.length - 1;
    }
    if (slot < _head) _head--;
    if (_head < _cursor) _head = _cursor;
  }

  /// Advance one slot. Returns the new position index, or null when the
  /// last slot has been reached — the session is over.
  int? next() {
    if (_slots.isEmpty) return null;
    if (_cursor >= _slots.length - 1) return null;
    _cursor++;
    if (_cursor > _head) _head = _cursor;
    return currentPositionIndex = _slots[_cursor];
  }

  /// Go back one slot, stopping at the first. Returns the position index
  /// now under the cursor, or null when the queue is empty.
  int? previous() {
    if (_slots.isEmpty) return null;
    if (_cursor > 0) _cursor--;
    return currentPositionIndex = _slots[_cursor];
  }
}

/// Per-game mistake counts, persisted, keyed by [GameRecord.dedupKey].
///
/// Reviewing a game used to happen twice: a full-game Stockfish pass wrote
/// `[%eval]` comments into the games cache so the list could count my
/// blunders, and then the tactics miner searched the *same* positions again to
/// turn those blunders into puzzles. Both passes classify a move the same way
/// (Lichess winning-chance swing: 0.10 / 0.20 / 0.30), so the second pass
/// already knew the counts — it just had nowhere to put them.
///
/// This is that place. The mining pass reports each game's counts as it
/// finishes, they are stored here, and the games list reads them. One engine
/// pass, both answers.
///
/// Keeping them here rather than in the PGN also means a game whose evals were
/// pruned, or which was mined before it was ever opened in the viewer, still
/// shows its counts.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../utils/safe_change_notifier.dart';

/// One game's mistake tally for the player whose games these are.
@immutable
class ReviewCounts {
  const ReviewCounts({
    required this.inaccuracies,
    required this.mistakes,
    required this.blunders,
  });

  final int inaccuracies;
  final int mistakes;
  final int blunders;

  @override
  bool operator ==(Object other) =>
      other is ReviewCounts &&
      other.inaccuracies == inaccuracies &&
      other.mistakes == mistakes &&
      other.blunders == blunders;

  @override
  int get hashCode => Object.hash(inaccuracies, mistakes, blunders);

  @override
  String toString() => 'ReviewCounts($inaccuracies/$mistakes/$blunders)';
}

class GameReviewStore extends ChangeNotifier with SafeChangeNotifier {
  GameReviewStore._();

  static final GameReviewStore instance = GameReviewStore._();

  /// Test-only: an isolated instance sharing the same prefs key.
  @visibleForTesting
  GameReviewStore.forTest();

  static const _prefsKey = 'game_review.counts';

  /// Oldest entries are dropped past this many. Insertion-ordered, so "oldest"
  /// means least recently reviewed, not least recently played.
  static const int maxEntries = 500;

  final Map<String, ReviewCounts> _counts = {};
  bool _loaded = false;
  Future<void>? _loading;

  bool get isLoaded => _loaded;
  int get length => _counts.length;

  Future<void> ensureLoaded() {
    if (_loaded) return Future.value();
    return _loading ??= _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = json.decode(raw);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            final value = entry.value;
            if (value is! List || value.length < 3) continue;
            _counts[entry.key as String] = ReviewCounts(
              inaccuracies: (value[0] as num).toInt(),
              mistakes: (value[1] as num).toInt(),
              blunders: (value[2] as num).toInt(),
            );
          }
        }
      } catch (e) {
        // A corrupt store is a cache miss, never a crash: the counts show as
        // "not reviewed" and the next run rewrites them.
        if (kDebugMode) debugPrint('[GameReviewStore] unreadable store: $e');
      }
    }
    _loaded = true;
    _loading = null;
    notifyListeners();
  }

  ReviewCounts? countsFor(String dedupKey) => _counts[dedupKey];

  /// Record one game's counts. Re-recording moves the game to the front of the
  /// eviction order, since a fresh review is the most relevant entry there is.
  Future<void> record(String dedupKey, ReviewCounts counts) async {
    if (dedupKey.isEmpty) return;
    await ensureLoaded();
    if (_counts[dedupKey] == counts) {
      // Same verdict as the stored one: nothing to notify or rewrite, but keep
      // it fresh in the eviction order.
      _counts
        ..remove(dedupKey)
        ..[dedupKey] = counts;
      return;
    }
    _counts
      ..remove(dedupKey)
      ..[dedupKey] = counts;
    while (_counts.length > maxEntries) {
      _counts.remove(_counts.keys.first);
    }
    notifyListeners();
    await _save();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      json.encode({
        for (final entry in _counts.entries)
          entry.key: [
            entry.value.inaccuracies,
            entry.value.mistakes,
            entry.value.blunders,
          ],
      }),
    );
  }

  /// Test hook: forget everything without touching prefs.
  @visibleForTesting
  void clearForTest() {
    _counts.clear();
    _loaded = true;
  }
}

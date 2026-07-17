/// Live Lichess Opening Explorer lookups for the **user-facing** explorer
/// panel only.
///
/// This is deliberately separate from the move-generation pipeline: the
/// generator must never hit the Lichess Explorer API (it would exhaust the
/// one-request-at-a-time rate limit), so it uses local frequency maps
/// instead. This service is what the human sees while browsing — one
/// position at a time, debounced, and cached.
///
/// Responsibilities:
///   • Debounce rapid position changes (scrubbing) so only the latest FEN
///     actually fetches.
///   • Coalesce in-flight requests: a response for a superseded FEN is
///     dropped rather than shown.
///   • Cache results (shared LRU) so revisiting a position is instant and
///     API-free.
///   • Surface a simple load state (idle/loading/data/error/rateLimited)
///     for the UI, honouring the client's 429 backoff window.
library;

import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../features/coverage/services/coverage_service.dart'
    show LichessDatabase;
import '../models/explorer_response.dart';
import 'lichess_api_client.dart';

enum ExplorerStatus { idle, loading, data, error, rateLimited }

/// Immutable snapshot of the explorer panel's current lookup.
@immutable
class ExplorerState {
  final ExplorerStatus status;

  /// FEN this state describes (null only for [ExplorerStatus.idle]).
  final String? fen;

  /// Parsed response; non-null only for [ExplorerStatus.data].
  final ExplorerResponse? data;

  const ExplorerState._(this.status, {this.fen, this.data});

  const ExplorerState.idle() : this._(ExplorerStatus.idle);
  const ExplorerState.loading(String fen)
    : this._(ExplorerStatus.loading, fen: fen);
  ExplorerState.data(ExplorerResponse response)
    : this._(ExplorerStatus.data, fen: response.fen, data: response);
  const ExplorerState.error(String fen)
    : this._(ExplorerStatus.error, fen: fen);
  const ExplorerState.rateLimited(String fen)
    : this._(ExplorerStatus.rateLimited, fen: fen);
}

/// Query parameters that identify a distinct explorer result.
@immutable
class ExplorerQuery {
  final LichessDatabase database;
  final Set<String> speeds;
  final Set<String> ratings;

  const ExplorerQuery({
    required this.database,
    this.speeds = const {'blitz', 'rapid', 'classical'},
    this.ratings = const {'2000', '2200', '2500'},
  });

  bool get useMasters => database == LichessDatabase.masters;
  String get speedsParam => (speeds.toList()..sort()).join(',');
  String get ratingsParam => (ratings.toList()..sort()).join(',');
}

class LiveExplorerService {
  LiveExplorerService({
    LichessApiClient? client,
    this.debounce = const Duration(milliseconds: 250),
  }) : _client = client ?? LichessApiClient.instance;

  final LichessApiClient _client;
  final Duration debounce;

  /// UI listens to this for spinner / rows / error banner.
  final ValueNotifier<ExplorerState> state = ValueNotifier(
    const ExplorerState.idle(),
  );

  // ── Shared LRU cache (across instances so reopening keeps results) ──
  static const int _maxCacheEntries = 256;
  static final LinkedHashMap<String, ExplorerResponse> _cache = LinkedHashMap();

  Timer? _debounceTimer;

  /// Monotonic request id; a completed fetch only wins if it is still the
  /// latest requested lookup (coalescing).
  int _requestSeq = 0;

  static String _cacheKey(String fen, ExplorerQuery q) => q.useMasters
      ? 'masters|$fen'
      : 'lichess|${q.speedsParam}|${q.ratingsParam}|$fen';

  /// Request explorer data for [fen]. Debounced and coalesced; the result is
  /// delivered via [state]. A cache hit resolves synchronously.
  void request(String fen, ExplorerQuery query) {
    _debounceTimer?.cancel();

    final cached = _cache[_cacheKey(fen, query)];
    if (cached != null) {
      // Refresh LRU recency and short-circuit — no network, no spinner.
      _touch(_cacheKey(fen, query), cached);
      _requestSeq++; // invalidate any in-flight fetch
      state.value = ExplorerState.data(cached);
      return;
    }

    final seq = ++_requestSeq;
    state.value = ExplorerState.loading(fen);
    _debounceTimer = Timer(debounce, () => _fetch(fen, query, seq));
  }

  Future<void> _fetch(String fen, ExplorerQuery query, int seq) async {
    final response = await _client.fetchExplorer(
      fen,
      speeds: query.speedsParam,
      ratings: query.ratingsParam,
      useMasters: query.useMasters,
    );

    // Superseded by a newer request — drop this result.
    if (seq != _requestSeq) return;

    if (response == null) {
      state.value = _client.isBackingOff
          ? ExplorerState.rateLimited(fen)
          : ExplorerState.error(fen);
      return;
    }

    _touch(_cacheKey(fen, query), response);
    state.value = ExplorerState.data(response);
  }

  void _touch(String key, ExplorerResponse value) {
    _cache.remove(key);
    _cache[key] = value;
    if (_cache.length > _maxCacheEntries) {
      _cache.remove(_cache.keys.first); // evict least-recently-used
    }
  }

  /// Clear the panel back to idle (e.g. when the explorer is hidden).
  void reset() {
    _debounceTimer?.cancel();
    _requestSeq++;
    state.value = const ExplorerState.idle();
  }

  void dispose() {
    _debounceTimer?.cancel();
    state.dispose();
  }

  @visibleForTesting
  static void clearCacheForTest() => _cache.clear();
}

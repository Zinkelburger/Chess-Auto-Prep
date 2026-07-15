/// Shared, keyed in-memory cache for Lichess Explorer position stats.
///
/// [ProbabilityService] and [CoverageService.getPositionData] are mothballed;
/// this service is the one live app-level path for Explorer move statistics.
/// It wraps [LichessApiClient.fetchExplorer] (which already handles auth,
/// politeness gaps, and 429 backoff) and adds:
///   • a cache keyed by database selection + normalised position, so the
///     same position is never fetched twice per source within a session
///   • in-flight request coalescing, so concurrent callers share one fetch
///   • simple LRU eviction to bound memory
///
/// Failures are never cached — a retry re-fetches.
library;

import '../models/explorer_response.dart';
import '../utils/fen_utils.dart';
import 'lichess_api_client.dart';

/// Which Explorer database to query, plus its filters.
///
/// Immutable value type; also serves as the cache-key prefix so responses
/// from different databases / filters never collide.
class ExplorerSourceConfig {
  /// Query the masters (titled-player OTB) database. Ignores
  /// [speeds]/[ratings] — the masters endpoint has no such filters.
  final bool useMasters;

  /// Comma-separated Lichess speed filters, e.g. 'blitz,rapid,classical'.
  final String speeds;

  /// Comma-separated Lichess rating-band filters, e.g. '2000,2200,2500'.
  final String ratings;

  const ExplorerSourceConfig({
    this.useMasters = false,
    this.speeds = 'blitz,rapid,classical',
    this.ratings = '2000,2200,2500',
  });

  String get cacheKeyPrefix =>
      useMasters ? 'masters' : 'lichess|$speeds|$ratings';

  @override
  bool operator ==(Object other) =>
      other is ExplorerSourceConfig &&
      other.useMasters == useMasters &&
      other.speeds == speeds &&
      other.ratings == ratings;

  @override
  int get hashCode => Object.hash(useMasters, speeds, ratings);
}

class ExplorerCacheService {
  ExplorerCacheService._(this._client);

  /// Application-wide shared instance (main thread).
  static final ExplorerCacheService instance = ExplorerCacheService._(
    LichessApiClient.instance,
  );

  /// Independent instance with an injectable client (unit tests).
  ExplorerCacheService.forTesting(LichessApiClient client) : this._(client);

  final LichessApiClient _client;

  static const int _maxEntries = 2000;

  /// LinkedHashMap insertion order doubles as LRU recency order.
  final Map<String, ExplorerResponse> _cache = {};
  final Map<String, Future<ExplorerResponse?>> _inFlight = {};

  /// Whether the underlying client is inside a 429-backoff window.
  bool get isRateLimited => _client.isBackingOff;

  String _key(String fen, ExplorerSourceConfig source) =>
      '${source.cacheKeyPrefix}|${normalizeFen(fen)}';

  /// Cached Explorer stats for [fen], or `null` on network/rate-limit
  /// failure (not cached; retry re-fetches).
  Future<ExplorerResponse?> fetch(String fen, ExplorerSourceConfig source) {
    final key = _key(fen, source);

    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached; // re-insert as most recently used
      return Future.value(cached);
    }

    final pending = _inFlight[key];
    if (pending != null) return pending;

    final future = _client
        .fetchExplorer(
          fen,
          speeds: source.speeds,
          ratings: source.ratings,
          useMasters: source.useMasters,
        )
        .then((response) {
          if (response != null) {
            _cache[key] = response;
            while (_cache.length > _maxEntries) {
              _cache.remove(_cache.keys.first);
            }
          }
          return response;
        })
        .whenComplete(() {
          // Block body, not `=> _inFlight.remove(key)`: remove() returns this
          // very future, and whenComplete awaits a returned future — the arrow
          // form deadlocks every fetch against itself.
          _inFlight.remove(key);
        });

    _inFlight[key] = future;
    return future;
  }

  /// Peek without fetching (for synchronous UI checks).
  ExplorerResponse? peek(String fen, ExplorerSourceConfig source) =>
      _cache[_key(fen, source)];

  void clear() => _cache.clear();
}

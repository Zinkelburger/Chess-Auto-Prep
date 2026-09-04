/// A map that forgets its least recently used entry once it passes a cap.
///
/// Four places in this app had grown the same hand-rolled idiom — re-insert
/// on read to refresh the order, then `while (length > max) remove(keys.first)`
/// — and two of them (the eval and Maia mirrors in `services/eval_cache.dart`)
/// had the cap missing entirely, which is how a long build ended up holding
/// every position it ever touched.  This is that idiom, once.
///
/// The order comes free from Dart's `Map`: the default implementation is a
/// `LinkedHashMap`, so `keys.first` is the oldest insertion and re-inserting a
/// key moves it to the end.  A read through [] promotes; [peek] deliberately
/// does not, for callers that only want to look.
library;

import 'package:flutter/foundation.dart';

class LruMap<K, V> {
  /// [maxEntries] must be positive; the map holds at most that many entries.
  LruMap({required this.maxEntries}) : assert(maxEntries > 0);

  final int maxEntries;

  final Map<K, V> _entries = {};

  /// Read [key] and mark it most-recently-used.
  ///
  /// Presence is tested with `containsKey` rather than a null return, so a
  /// map whose [V] is nullable still promotes an entry whose value is null.
  V? operator [](K key) {
    if (!_entries.containsKey(key)) return null;
    final value = _entries.remove(key) as V;
    _entries[key] = value;
    return value;
  }

  /// Read [key] without touching the eviction order.
  V? peek(K key) => _entries[key];

  /// Store [value], evicting the oldest entries if that puts us over the cap.
  void operator []=(K key, V value) {
    _entries.remove(key);
    _entries[key] = value;
    _evict();
  }

  /// Store [value] only if [key] is absent, and mark it most-recently-used
  /// either way.  Mirrors `Map.putIfAbsent`.
  V putIfAbsent(K key, V Function() ifAbsent) {
    if (_entries.containsKey(key)) {
      final existing = _entries.remove(key) as V;
      _entries[key] = existing;
      return existing;
    }
    final value = ifAbsent();
    _entries[key] = value;
    _evict();
    return value;
  }

  bool containsKey(K key) => _entries.containsKey(key);

  V? remove(K key) => _entries.remove(key);

  void clear() => _entries.clear();

  int get length => _entries.length;

  bool get isEmpty => _entries.isEmpty;

  bool get isNotEmpty => _entries.isNotEmpty;

  /// Oldest first — the order entries would be evicted in.
  Iterable<K> get keys => _entries.keys;

  Iterable<V> get values => _entries.values;

  Iterable<MapEntry<K, V>> get entries => _entries.entries;

  /// The live backing map, for callers that must serialise the whole cache.
  /// Iteration order is oldest-first; mutating it bypasses the cap.
  @visibleForTesting
  Map<K, V> get backing => _entries;

  void _evict() {
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }
}

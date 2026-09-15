import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/solitaire_trophy.dart';
import 'storage/storage_factory.dart';

/// Singleton service for loading, saving, and managing solitaire trophies.
///
/// Trophies are persisted as a JSON array in `solitaire_trophies.json` in the
/// app documents directory, newest first. The list is read once and then
/// kept in memory; every mutation rewrites the whole file.
class SolitaireTrophyService {
  SolitaireTrophyService._();
  static final instance = SolitaireTrophyService._();

  static const _fileName = 'solitaire_trophies.json';

  List<SolitaireTrophy>? _cache;

  /// Every trophy, newest first. Read-only; mutate through [addTrophy],
  /// [addTrophies], [deleteById] and [clearAll].
  Future<List<SolitaireTrophy>> loadAll() async =>
      List.unmodifiable(await _loaded());

  Future<void> addTrophy(SolitaireTrophy trophy) => addTrophies([trophy]);

  Future<void> addTrophies(List<SolitaireTrophy> trophies) async {
    if (trophies.isEmpty) return;
    await _persist([...trophies, ...await _loaded()]);
  }

  Future<void> deleteById(String id) async {
    final remaining = [
      for (final trophy in await _loaded())
        if (trophy.id != id) trophy,
    ];
    await _persist(remaining);
  }

  Future<void> clearAll() => _persist([]);

  /// The cached list, read from disk on first use. A missing, empty or
  /// unreadable file is an empty shelf, never an error.
  Future<List<SolitaireTrophy>> _loaded() async {
    final cached = _cache;
    if (cached != null) return cached;
    final content = await StorageFactory.instance.readFile(_fileName);
    if (content == null || content.trim().isEmpty) return _cache = [];
    try {
      return _cache = (jsonDecode(content) as List)
          .cast<Map<String, dynamic>>()
          .map(SolitaireTrophy.fromJson)
          .toList();
    } catch (e) {
      debugPrint('Failed to parse trophies: $e');
      return _cache = [];
    }
  }

  Future<void> _persist(List<SolitaireTrophy> trophies) async {
    _cache = trophies;
    final json = jsonEncode([for (final t in trophies) t.toJson()]);
    await StorageFactory.instance.writeFile(_fileName, json);
  }
}

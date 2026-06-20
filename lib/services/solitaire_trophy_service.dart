import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/solitaire_trophy.dart';
import 'storage/storage_factory.dart';

/// Singleton service for loading, saving, and managing solitaire trophies.
///
/// Trophies are persisted as a JSON array in `solitaire_trophies.json` in the
/// app documents directory.
class SolitaireTrophyService {
  SolitaireTrophyService._();
  static final instance = SolitaireTrophyService._();

  static const _fileName = 'solitaire_trophies.json';

  List<SolitaireTrophy>? _cache;

  Future<List<SolitaireTrophy>> loadAll() async {
    if (_cache != null) return List.unmodifiable(_cache!);
    final storage = StorageFactory.instance;
    final content = await storage.readFile(_fileName);
    if (content == null || content.trim().isEmpty) {
      _cache = [];
      return const [];
    }
    try {
      final list = (jsonDecode(content) as List)
          .cast<Map<String, dynamic>>()
          .map(SolitaireTrophy.fromJson)
          .toList();
      _cache = list;
      return List.unmodifiable(list);
    } catch (e) {
      debugPrint('Failed to parse trophies: $e');
      _cache = [];
      return const [];
    }
  }

  Future<void> addTrophy(SolitaireTrophy trophy) async {
    final all = List<SolitaireTrophy>.from(await loadAll());
    all.insert(0, trophy);
    _cache = all;
    await _persist();
  }

  Future<void> addTrophies(List<SolitaireTrophy> trophies) async {
    if (trophies.isEmpty) return;
    final all = List<SolitaireTrophy>.from(await loadAll());
    all.insertAll(0, trophies);
    _cache = all;
    await _persist();
  }

  Future<void> deleteById(String id) async {
    final all = List<SolitaireTrophy>.from(await loadAll());
    all.removeWhere((t) => t.id == id);
    _cache = all;
    await _persist();
  }

  Future<void> clearAll() async {
    _cache = [];
    await _persist();
  }

  int get count => _cache?.length ?? 0;

  Future<void> _persist() async {
    final json = jsonEncode(_cache!.map((t) => t.toJson()).toList());
    await StorageFactory.instance.writeFile(_fileName, json);
  }
}

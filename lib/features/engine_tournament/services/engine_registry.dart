/// The list of engines available to the tournament feature.
///
/// The bundled Stockfish is always the first entry and its *path* is never
/// persisted — it is extracted at runtime and would go stale across installs.
/// Its settings (Hash, Threads, Ponder, extra options) are persisted, because
/// "give the bundled engine 4 threads for this match" is an ordinary thing to
/// want and there is nowhere else to say it.
///
/// Every other entry is a binary the user pointed at and that passed
/// [verifyUciEngine]; nothing else in the app ever launches those.
library;

import 'dart:convert';
import 'dart:io';

import '../../../utils/atomic_file.dart';
import '../models/engine_spec.dart';

class EngineRegistry {
  EngineRegistry(this.file);

  /// `Documents/engine_tournaments/engines.json`.
  final File file;

  /// Every stored entry, bundled override included. Always a fresh growable
  /// list — callers mutate the result.
  Future<List<EngineSpec>> _loadStored() async {
    if (!await file.exists()) return <EngineSpec>[];
    try {
      final json = jsonDecode(await file.readAsString());
      if (json is! List) return <EngineSpec>[];
      return json
          .whereType<Map>()
          .map((e) => EngineSpec.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      // A hand-edited or half-written file should cost the user their list,
      // not the whole screen.
      return <EngineSpec>[];
    }
  }

  /// User-added engines, in the order they were added.
  Future<List<EngineSpec>> loadUserEngines() async {
    final stored = await _loadStored();
    stored.removeWhere((e) => e.id == EngineSpec.bundledId || e.isBundled);
    return stored;
  }

  /// Bundled Stockfish first, then everything the user added.
  Future<List<EngineSpec>> loadAll() async {
    final stored = await _loadStored();
    final bundled = stored
        .where((e) => e.id == EngineSpec.bundledId)
        .firstOrNull;
    return [
      (bundled ?? EngineSpec.bundledStockfish).copyWith(
        executablePath: null,
        id: EngineSpec.bundledId,
      ),
      ...stored.where((e) => e.id != EngineSpec.bundledId && !e.isBundled),
    ];
  }

  Future<void> _save(List<EngineSpec> engines) async {
    await file.parent.create(recursive: true);
    final payload = const JsonEncoder.withIndent(
      '  ',
    ).convert(engines.map((e) => e.toJson()).toList());
    await writeTextFileAtomically(file, payload);
  }

  Future<List<EngineSpec>> add(EngineSpec spec) async {
    if (spec.isBundled) return loadAll();
    final stored = await _loadStored();
    stored.add(spec.id.isEmpty ? spec.copyWith(id: newEngineId()) : spec);
    await _save(stored);
    return loadAll();
  }

  /// Update an entry, or create it if it is not stored yet — which is how the
  /// bundled engine's settings first get written down.
  Future<List<EngineSpec>> update(EngineSpec spec) async {
    final normalized = spec.id == EngineSpec.bundledId
        ? spec.copyWith(executablePath: null)
        : spec;
    final stored = await _loadStored();
    final index = stored.indexWhere((e) => e.id == normalized.id);
    if (index < 0) {
      stored.add(normalized);
    } else {
      stored[index] = normalized;
    }
    await _save(stored);
    return loadAll();
  }

  /// Remove a user engine. The bundled entry cannot be removed; clearing its
  /// stored settings just returns it to the defaults.
  Future<List<EngineSpec>> remove(String id) async {
    final stored = await _loadStored();
    stored.removeWhere((e) => e.id == id);
    await _save(stored);
    return loadAll();
  }
}

/// Ids only have to be unique within one machine's registry, and be stable
/// once a tournament has referenced them.
String newEngineId() =>
    'engine-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

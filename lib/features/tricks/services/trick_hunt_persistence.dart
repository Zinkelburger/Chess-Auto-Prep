/// Persistence for trick-hunt reports, stored as a JSON file whose path the
/// caller supplies (Player Analysis keys it per player and colour). No
/// resume state: v1 hunts are re-run from scratch; cancels save partial
/// reports.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../services/storage/storage_factory.dart';
import '../../audit/models/audit_result.dart';
import 'trick_hunt_config.dart';

class TrickHuntSnapshot {
  final AuditResult result;
  final TrickHuntConfig config;

  /// False when the hunt was cancelled partway; kept in the JSON so resume
  /// support can be added later without a format break.
  final bool isComplete;

  const TrickHuntSnapshot({
    required this.result,
    required this.config,
    this.isComplete = true,
  });

  Map<String, dynamic> toJson() => {
    'version': 1,
    'isComplete': isComplete,
    if (!isComplete) 'partial': true,
    'config': config.toMap(),
    'result': result.toJson(),
  };

  factory TrickHuntSnapshot.fromJson(Map<String, dynamic> j) =>
      TrickHuntSnapshot(
        result: AuditResult.fromJson(j['result'] as Map<String, dynamic>),
        config: j['config'] != null
            ? TrickHuntConfig.fromMap(j['config'] as Map<String, dynamic>)
            : const TrickHuntConfig(),
        isComplete: j['isComplete'] as bool? ?? true,
      );
}

class TrickHuntPersistence {
  TrickHuntPersistence._();
  static final instance = TrickHuntPersistence._();

  /// Load a previously saved report from [path].
  /// Returns `null` if no file exists or it fails to parse.
  Future<TrickHuntSnapshot?> load(String? path) async {
    if (path == null || path.isEmpty) return null;
    try {
      final exists = await StorageFactory.instance.fileExists(path);
      if (!exists) return null;
      final json = await StorageFactory.instance.readFile(path);
      if (json == null || json.isEmpty) return null;
      final snapshot = TrickHuntSnapshot.fromJson(
        jsonDecode(json) as Map<String, dynamic>,
      );
      debugPrint(
        '[TrickHuntPersistence] restored ${snapshot.result.findings.length} '
        'findings from $path',
      );
      return snapshot;
    } catch (e) {
      debugPrint('[TrickHuntPersistence] Failed to load: $e');
      return null;
    }
  }

  /// Save a report (complete, or partial after a cancel) to [path].
  Future<void> save(
    String? path,
    AuditResult result,
    TrickHuntConfig config, {
    bool isComplete = true,
  }) async {
    await _write(
      path,
      TrickHuntSnapshot(result: result, config: config, isComplete: isComplete),
    );
  }

  /// Re-save the current result (e.g. after dismissal changes), preserving
  /// the stored config when none is supplied.
  Future<void> saveResult(
    String? path,
    AuditResult result, {
    TrickHuntConfig? config,
  }) async {
    TrickHuntConfig effectiveConfig = config ?? const TrickHuntConfig();
    if (config == null) {
      try {
        final existing = await load(path);
        if (existing != null) effectiveConfig = existing.config;
      } catch (_) {
        // Best-effort; failure here is non-fatal and intentionally ignored.
      }
    }
    await _write(
      path,
      TrickHuntSnapshot(result: result, config: effectiveConfig),
    );
  }

  Future<void> _write(String? path, TrickHuntSnapshot snapshot) async {
    if (path == null || path.isEmpty) return;
    try {
      await StorageFactory.instance.writeFile(
        path,
        jsonEncode(snapshot.toJson()),
      );
      debugPrint(
        '[TrickHuntPersistence] saved ${snapshot.result.findings.length} '
        'findings (complete=${snapshot.isComplete}) to $path',
      );
    } catch (e) {
      debugPrint('[TrickHuntPersistence] Failed to save: $e');
    }
  }
}

/// Persistence for hole-hunt reports, stored alongside the repertoire PGN
/// as `*_holes.json`. Mirrors [AuditPersistence] but without resume state
/// (v1 hunts are re-run from scratch; cancels save partial reports).
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../services/storage/storage_factory.dart';
import '../../audit/models/audit_result.dart';
import 'hole_hunt_config.dart';

class HoleHuntSnapshot {
  final AuditResult result;
  final HoleHuntConfig config;

  /// False when the hunt was cancelled partway; kept in the JSON so resume
  /// support can be added later without a format break.
  final bool isComplete;

  const HoleHuntSnapshot({
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

  factory HoleHuntSnapshot.fromJson(Map<String, dynamic> j) =>
      HoleHuntSnapshot(
        result: AuditResult.fromJson(j['result'] as Map<String, dynamic>),
        config: j['config'] != null
            ? HoleHuntConfig.fromMap(j['config'] as Map<String, dynamic>)
            : const HoleHuntConfig(),
        isComplete: j['isComplete'] as bool? ?? true,
      );
}

class HoleHuntPersistence {
  HoleHuntPersistence._();
  static final instance = HoleHuntPersistence._();

  /// Derive the holes JSON path from the repertoire PGN path.
  String? holesPath(String? repertoireFilePath) {
    if (repertoireFilePath == null || repertoireFilePath.isEmpty) return null;
    final base = p.withoutExtension(repertoireFilePath);
    return '${base}_holes.json';
  }

  /// Load a previously saved report for the given repertoire.
  /// Returns `null` if no file exists or it fails to parse.
  Future<HoleHuntSnapshot?> load(String? repertoireFilePath) async {
    final path = holesPath(repertoireFilePath);
    if (path == null) return null;
    try {
      final exists = await StorageFactory.instance.fileExists(path);
      if (!exists) return null;
      final json = await StorageFactory.instance.readFile(path);
      if (json == null || json.isEmpty) return null;
      final snapshot =
          HoleHuntSnapshot.fromJson(jsonDecode(json) as Map<String, dynamic>);
      debugPrint(
          '[HoleHuntPersistence] restored ${snapshot.result.findings.length} '
          'findings from $path');
      return snapshot;
    } catch (e) {
      debugPrint('[HoleHuntPersistence] Failed to load: $e');
      return null;
    }
  }

  /// Save a report (complete, or partial after a cancel).
  Future<void> save(
    String? repertoireFilePath,
    AuditResult result,
    HoleHuntConfig config, {
    bool isComplete = true,
  }) async {
    await _write(
      repertoireFilePath,
      HoleHuntSnapshot(result: result, config: config, isComplete: isComplete),
    );
  }

  /// Re-save the current result (e.g. after dismissal changes), preserving
  /// the stored config when none is supplied.
  Future<void> saveResult(
    String? repertoireFilePath,
    AuditResult result, {
    HoleHuntConfig? config,
  }) async {
    HoleHuntConfig effectiveConfig = config ?? const HoleHuntConfig();
    if (config == null) {
      try {
        final existing = await load(repertoireFilePath);
        if (existing != null) effectiveConfig = existing.config;
      } catch (_) {
        // Best-effort; failure here is non-fatal and intentionally ignored.
      }
    }
    await _write(
      repertoireFilePath,
      HoleHuntSnapshot(result: result, config: effectiveConfig),
    );
  }

  Future<void> _write(
      String? repertoireFilePath, HoleHuntSnapshot snapshot) async {
    final path = holesPath(repertoireFilePath);
    if (path == null) return;
    try {
      await StorageFactory.instance
          .writeFile(path, jsonEncode(snapshot.toJson()));
      debugPrint(
          '[HoleHuntPersistence] saved ${snapshot.result.findings.length} '
          'findings (complete=${snapshot.isComplete}) to $path');
    } catch (e) {
      debugPrint('[HoleHuntPersistence] Failed to save: $e');
    }
  }
}

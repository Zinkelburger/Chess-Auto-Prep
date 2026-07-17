/// Centralized persistence for audit results and progress.
///
/// Stores results alongside the repertoire PGN file as `*_audit.json`.
/// Handles save, load, and auto-save of dismissal changes so that
/// audit state survives app restarts.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../services/storage/storage_factory.dart';
import '../models/audit_result.dart';
import 'audit_config.dart';

/// Envelope wrapping an [AuditResult] with its [AuditConfig] and progress
/// metadata so that an interrupted audit can be resumed.
class AuditSnapshot {
  final AuditResult result;
  final AuditConfig config;

  /// FENs of nodes already checked, used to skip them on resume.
  final Set<String> checkedFens;

  /// Whether this snapshot represents a completed audit.
  final bool isComplete;

  const AuditSnapshot({
    required this.result,
    required this.config,
    this.checkedFens = const {},
    this.isComplete = true,
  });

  Map<String, dynamic> toJson() => {
    'version': 2,
    'isComplete': isComplete,
    'config': config.toMap(),
    'result': result.toJson(),
    if (!isComplete) 'checkedFens': checkedFens.toList(),
  };

  factory AuditSnapshot.fromJson(Map<String, dynamic> j) {
    final version = j['version'] as int? ?? 1;

    if (version < 2) {
      return AuditSnapshot(
        result: AuditResult.fromJson(j),
        config: const AuditConfig(),
        isComplete: true,
      );
    }

    return AuditSnapshot(
      result: AuditResult.fromJson(j['result'] as Map<String, dynamic>),
      config: j['config'] != null
          ? AuditConfig.fromMap(j['config'] as Map<String, dynamic>)
          : const AuditConfig(),
      checkedFens: j['checkedFens'] != null
          ? (j['checkedFens'] as List).cast<String>().toSet()
          : const {},
      isComplete: j['isComplete'] as bool? ?? true,
    );
  }
}

class AuditPersistence {
  AuditPersistence._();
  static final instance = AuditPersistence._();

  /// Derive the audit JSON path from the repertoire PGN path.
  String? auditPath(String? repertoireFilePath) {
    if (repertoireFilePath == null || repertoireFilePath.isEmpty) return null;
    final base = p.withoutExtension(repertoireFilePath);
    return '${base}_audit.json';
  }

  /// Load a previously saved audit snapshot for the given repertoire.
  /// Returns `null` if no file exists or it fails to parse.
  Future<AuditSnapshot?> load(String? repertoireFilePath) async {
    final path = auditPath(repertoireFilePath);
    if (path == null) {
      debugPrint('[AuditPersistence] load: no path for "$repertoireFilePath"');
      return null;
    }
    try {
      final exists = await StorageFactory.instance.fileExists(path);
      if (!exists) {
        debugPrint('[AuditPersistence] load: file not found at $path');
        return null;
      }
      final json = await StorageFactory.instance.readFile(path);
      if (json == null || json.isEmpty) {
        debugPrint('[AuditPersistence] load: file empty at $path');
        return null;
      }
      final snapshot = AuditSnapshot.fromJson(
        jsonDecode(json) as Map<String, dynamic>,
      );
      debugPrint(
        '[AuditPersistence] load: restored ${snapshot.result.findings.length} '
        'findings, isComplete=${snapshot.isComplete} from $path',
      );
      return snapshot;
    } catch (e) {
      debugPrint('[AuditPersistence] Failed to load: $e');
      return null;
    }
  }

  /// Save a complete audit result with its config.
  Future<void> saveComplete(
    String? repertoireFilePath,
    AuditResult result,
    AuditConfig config,
  ) async {
    final snapshot = AuditSnapshot(
      result: result,
      config: config,
      isComplete: true,
    );
    await _write(repertoireFilePath, snapshot);
  }

  /// Save partial progress so it can be resumed later.
  Future<void> saveProgress(
    String? repertoireFilePath,
    AuditResult partialResult,
    AuditConfig config,
    Set<String> checkedFens,
  ) async {
    final snapshot = AuditSnapshot(
      result: partialResult,
      config: config,
      checkedFens: checkedFens,
      isComplete: false,
    );
    await _write(repertoireFilePath, snapshot);
  }

  /// Re-save the current result (e.g. after dismissal changes).
  Future<void> saveResult(
    String? repertoireFilePath,
    AuditResult result, {
    AuditConfig? config,
  }) async {
    final path = auditPath(repertoireFilePath);
    if (path == null) return;

    AuditConfig effectiveConfig = config ?? const AuditConfig();
    try {
      final existing = await load(repertoireFilePath);
      if (existing != null && config == null) {
        effectiveConfig = existing.config;
      }
    } catch (_) {
      // Best-effort; failure here is non-fatal and intentionally ignored.
    }

    final snapshot = AuditSnapshot(
      result: result,
      config: effectiveConfig,
      isComplete: true,
    );
    await _write(repertoireFilePath, snapshot);
  }

  Future<void> _write(
    String? repertoireFilePath,
    AuditSnapshot snapshot,
  ) async {
    final path = auditPath(repertoireFilePath);
    if (path == null) {
      debugPrint(
        '[AuditPersistence] _write: no path for "$repertoireFilePath"',
      );
      return;
    }
    try {
      final json = jsonEncode(snapshot.toJson());
      await StorageFactory.instance.writeFile(path, json);
      debugPrint(
        '[AuditPersistence] saved ${snapshot.result.findings.length} '
        'findings (complete=${snapshot.isComplete}) to $path',
      );
    } catch (e) {
      debugPrint('[AuditPersistence] Failed to save: $e');
    }
  }
}

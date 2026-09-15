/// Centralized persistence for audit results and progress.
///
/// Stores results alongside the repertoire PGN file as `*_audit.json`.
/// Handles save, load, and auto-save of dismissal changes so that
/// audit state survives app restarts.
library;

import 'dart:async';
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

  /// Null audits the chapter root; otherwise resume the original subtree.
  final String? startFen;

  const AuditSnapshot({
    required this.result,
    required this.config,
    this.checkedFens = const {},
    this.isComplete = true,
    this.startFen,
  });

  Map<String, dynamic> toJson() => {
    'version': 2,
    'isComplete': isComplete,
    if (startFen != null) 'startFen': startFen,
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
      startFen: j['startFen'] as String?,
    );
  }
}

class AuditPersistence {
  AuditPersistence._();
  static final instance = AuditPersistence._();

  /// The write in flight per audit path, so a load waits for it and a later
  /// write queues behind it instead of racing on the file.
  final Map<String, Future<void>> _writes = {};

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
      await _writes[path];
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
    AuditConfig config, {
    String? startFen,
  }) async {
    final snapshot = AuditSnapshot(
      result: result,
      config: config,
      startFen: startFen,
      isComplete: true,
    );
    await _write(repertoireFilePath, snapshot);
  }

  /// Save partial progress so it can be resumed later.
  Future<void> saveProgress(
    String? repertoireFilePath,
    AuditResult partialResult,
    AuditConfig config,
    Set<String> checkedFens, {
    String? startFen,
  }) async {
    final snapshot = AuditSnapshot(
      result: partialResult,
      config: config,
      checkedFens: checkedFens,
      startFen: startFen,
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

    // Best-effort: [load] answers null rather than throwing, and with no
    // stored config the defaults are the only thing left to write.
    final existing = await load(repertoireFilePath);
    final snapshot = AuditSnapshot(
      result: result,
      config: config ?? existing?.config ?? const AuditConfig(),
      isComplete: existing?.isComplete ?? true,
      checkedFens: existing?.checkedFens ?? const {},
      startFen: existing?.startFen,
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
    final storage = StorageFactory.instance;
    final json = jsonEncode(snapshot.toJson());
    final previous = _writes[path];
    final write = () async {
      await previous;
      try {
        await storage.writeFile(path, json);
      } catch (e) {
        debugPrint('[AuditPersistence] Failed to save: $e');
      }
    }();
    _writes[path] = write;
    await write;
    if (identical(_writes[path], write)) unawaited(_writes.remove(path));
  }
}

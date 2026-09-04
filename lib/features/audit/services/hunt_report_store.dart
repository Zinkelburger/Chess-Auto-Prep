/// Saving and restoring a hunt report — the findings plus the config that
/// produced them — as a JSON file at a path the caller supplies.
///
/// The hole hunt and the trick hunt each had their own copy of this: two
/// 123-line files that differed only in the word "hole" versus "trick". They
/// were not going to stay in step, and the format they share is the whole
/// point — Player Analysis keys both per player and colour, and reads them
/// back the same way.
///
/// Generic over the config type rather than over an interface, because
/// [HoleHuntConfig] and [TrickHuntConfig] have nothing in common beyond a map
/// round-trip; a shared base class would be a name for that coincidence and
/// nothing more. The two function arguments *are* the contract.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../services/storage/storage_factory.dart';
import '../models/audit_result.dart';

/// One saved report.
class HuntSnapshot<C> {
  const HuntSnapshot({
    required this.result,
    required this.config,
    this.isComplete = true,
  });

  final AuditResult result;
  final C config;

  /// False when the hunt was cancelled partway; kept in the JSON so resume
  /// support can be added later without a format break.
  final bool isComplete;
}

/// Reads and writes [HuntSnapshot]s for one kind of hunt.
///
/// Every operation is best-effort: a report that fails to load reads as "no
/// report yet", and a report that fails to save leaves the previous one in
/// place. Neither is worth interrupting the user for — the hunt itself is the
/// expensive part and its results are still on screen.
class HuntReportStore<C> {
  const HuntReportStore({
    required this.label,
    required this.encodeConfig,
    required this.decodeConfig,
  });

  /// Names this store in debug output ("HoleHunt", "TrickHunt").
  final String label;

  final Map<String, dynamic> Function(C config) encodeConfig;

  /// Rebuilds the config from stored JSON. Called with null for a report
  /// written before configs were stored, so it must have a default to give.
  final C Function(Map<String, dynamic>? stored) decodeConfig;

  /// The wire form of [snapshot]. Public so a round-trip is testable without
  /// touching the filesystem.
  Map<String, dynamic> encode(HuntSnapshot<C> snapshot) => {
    'version': 1,
    'isComplete': snapshot.isComplete,
    if (!snapshot.isComplete) 'partial': true,
    'config': encodeConfig(snapshot.config),
    'result': snapshot.result.toJson(),
  };

  HuntSnapshot<C> decode(Map<String, dynamic> json) => HuntSnapshot<C>(
    result: AuditResult.fromJson(json['result'] as Map<String, dynamic>),
    config: decodeConfig(json['config'] as Map<String, dynamic>?),
    isComplete: json['isComplete'] as bool? ?? true,
  );

  /// Load a previously saved report from [path], or null when there is none
  /// and when one is there but unreadable.
  Future<HuntSnapshot<C>?> load(String? path) async {
    if (path == null || path.isEmpty) return null;
    try {
      if (!await StorageFactory.instance.fileExists(path)) return null;
      final json = await StorageFactory.instance.readFile(path);
      if (json == null || json.isEmpty) return null;
      final snapshot = decode(jsonDecode(json) as Map<String, dynamic>);
      debugPrint(
        '[$label] restored ${snapshot.result.findings.length} '
        'findings from $path',
      );
      return snapshot;
    } catch (e) {
      debugPrint('[$label] Failed to load: $e');
      return null;
    }
  }

  /// Save a report — complete, or partial after a cancel — to [path].
  Future<void> save(
    String? path,
    AuditResult result,
    C config, {
    bool isComplete = true,
  }) => _write(
    path,
    HuntSnapshot<C>(result: result, config: config, isComplete: isComplete),
  );

  /// Re-save the current result after something changed that is not the
  /// findings themselves — a dismissal, say.
  ///
  /// With no [config], the stored one is kept: the caller changing a
  /// dismissal has no opinion about the config, and overwriting it with a
  /// default would quietly relabel the report as a default-settings run.
  Future<void> saveResult(String? path, AuditResult result, {C? config}) async {
    final C effective;
    if (config != null) {
      effective = config;
    } else {
      final existing = await load(path);
      effective = existing?.config ?? decodeConfig(null);
    }
    await _write(path, HuntSnapshot<C>(result: result, config: effective));
  }

  Future<void> _write(String? path, HuntSnapshot<C> snapshot) async {
    if (path == null || path.isEmpty) return;
    try {
      await StorageFactory.instance.writeFile(
        path,
        jsonEncode(encode(snapshot)),
      );
      debugPrint(
        '[$label] saved ${snapshot.result.findings.length} findings '
        '(complete=${snapshot.isComplete}) to $path',
      );
    } catch (e) {
      debugPrint('[$label] Failed to save: $e');
    }
  }
}

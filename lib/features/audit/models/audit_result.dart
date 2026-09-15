/// Aggregate result of a repertoire audit pass or a hole hunt.
///
/// [toJson]/[fromJson] are the persisted report format (schema `version` 1);
/// keys are append-only so older reports keep loading.
library;

import 'dart:convert';

import 'audit_finding.dart';

class AuditResult {
  AuditResult({
    required this.findings,
    required this.nodesChecked,
    required this.ourMoveNodesChecked,
    required this.opponentNodesChecked,
    required this.leafNodesChecked,
    this.evalCacheHits = 0,
    this.evalCacheMisses = 0,
    required this.elapsed,
    DateTime? timestamp,
    this.warnings = const [],
  }) : timestamp = timestamp ?? DateTime.now();

  final List<AuditFinding> findings;
  final int nodesChecked;
  final int ourMoveNodesChecked;
  final int opponentNodesChecked;
  final int leafNodesChecked;
  final int evalCacheHits;
  final int evalCacheMisses;
  final Duration elapsed;

  /// When the run finished, or when a stored report was written.
  final DateTime timestamp;

  /// Enabled sources that could not check all requested positions.
  final List<String> warnings;

  static final empty = AuditResult(
    findings: const [],
    nodesChecked: 0,
    ourMoveNodesChecked: 0,
    opponentNodesChecked: 0,
    leafNodesChecked: 0,
    elapsed: Duration.zero,
  );

  int get totalEvalLookups => evalCacheHits + evalCacheMisses;

  double get evalCacheHitPercent =>
      totalEvalLookups > 0 ? (evalCacheHits / totalEvalLookups) * 100 : 0;

  List<AuditFinding> _ofType(AuditFindingType type) =>
      findings.where((f) => f.type == type).toList();

  int _countType(AuditFindingType type) =>
      findings.where((f) => f.type == type).length;

  int _countSeverity(AuditSeverity severity) =>
      findings.where((f) => f.severity == severity).length;

  int get mistakeCount => _countType(AuditFindingType.mistake);
  int get inaccuracyCount => _countType(AuditFindingType.inaccuracy);
  int get missingResponseCount => _countType(AuditFindingType.missingResponse);
  int get weakPositionCount => _countType(AuditFindingType.weakPosition);
  int get deadEndCount => _countType(AuditFindingType.deadEnd);

  int get criticalCount => _countSeverity(AuditSeverity.critical);
  int get warningCount => _countSeverity(AuditSeverity.warning);
  int get infoCount => _countSeverity(AuditSeverity.info);

  int get activeFindingCount => findings.where((f) => !f.dismissed).length;

  /// Share of our-move positions with no mistake, inaccuracy or weak
  /// position among their moves.
  double get soundnessPercent {
    if (ourMoveNodesChecked == 0) return 100.0;
    final affectedPositions = findings
        .where(
          (f) => switch (f.type) {
            AuditFindingType.mistake ||
            AuditFindingType.inaccuracy ||
            AuditFindingType.weakPosition => true,
            _ => false,
          },
        )
        // The finding's path ends with our move; its parent is the position.
        .map(
          (f) => f.movePath
              .take(f.movePath.isEmpty ? 0 : f.movePath.length - 1)
              .join(' '),
        )
        .toSet()
        .length;
    final sound = (ourMoveNodesChecked - affectedPositions).clamp(
      0,
      ourMoveNodesChecked,
    );
    return sound / ourMoveNodesChecked * 100;
  }

  /// Fraction of opponent-turn nodes where every common reply is covered.
  /// Dead ends are excluded -- they're leaf nodes counted in
  /// [leafNodesChecked], not [opponentNodesChecked].
  double get coveragePercent {
    if (opponentNodesChecked == 0) return 100.0;
    final nodesWithGaps = missingResponses.map((f) => f.fen).toSet().length;
    final covered = (opponentNodesChecked - nodesWithGaps).clamp(
      0,
      opponentNodesChecked,
    );
    return covered / opponentNodesChecked * 100;
  }

  List<AuditFinding> get mistakes => _ofType(AuditFindingType.mistake);
  List<AuditFinding> get inaccuracies => _ofType(AuditFindingType.inaccuracy);
  List<AuditFinding> get missingResponses =>
      _ofType(AuditFindingType.missingResponse);
  List<AuditFinding> get weakPositions =>
      _ofType(AuditFindingType.weakPosition);
  List<AuditFinding> get deadEnds => _ofType(AuditFindingType.deadEnd);

  // ── JSON serialization ────────────────────────────────────────────────

  String toJsonString() => jsonEncode(toJson());

  Map<String, dynamic> toJson() => {
    'version': 1,
    'timestamp': timestamp.toIso8601String(),
    'nodesChecked': nodesChecked,
    'ourMoveNodesChecked': ourMoveNodesChecked,
    'opponentNodesChecked': opponentNodesChecked,
    'leafNodesChecked': leafNodesChecked,
    'evalCacheHits': evalCacheHits,
    'evalCacheMisses': evalCacheMisses,
    'elapsedMs': elapsed.inMilliseconds,
    'findings': findings.map((f) => f.toJson()).toList(),
    if (warnings.isNotEmpty) 'warnings': warnings,
  };

  factory AuditResult.fromJsonString(String s) =>
      AuditResult.fromJson(jsonDecode(s) as Map<String, dynamic>);

  factory AuditResult.fromJson(Map<String, dynamic> j) {
    // A finding type this build no longer has (a report written by an older
    // hunt) drops out on its own rather than taking the whole report with it.
    final knownTypes = AuditFindingType.values.map((t) => t.name).toSet();
    final findings = (j['findings'] as List)
        .cast<Map<String, dynamic>>()
        .where((e) => knownTypes.contains(e['type']))
        .map(AuditFinding.fromJson)
        .toList();
    return AuditResult(
      findings: findings,
      warnings: (j['warnings'] as List?)?.cast<String>() ?? const [],
      nodesChecked: j['nodesChecked'] as int? ?? 0,
      ourMoveNodesChecked: j['ourMoveNodesChecked'] as int? ?? 0,
      opponentNodesChecked: j['opponentNodesChecked'] as int? ?? 0,
      leafNodesChecked: j['leafNodesChecked'] as int? ?? 0,
      evalCacheHits: j['evalCacheHits'] as int? ?? 0,
      evalCacheMisses: j['evalCacheMisses'] as int? ?? 0,
      elapsed: Duration(milliseconds: j['elapsedMs'] as int? ?? 0),
      timestamp: j['timestamp'] != null
          ? DateTime.tryParse(j['timestamp'] as String)
          : null,
    );
  }
}

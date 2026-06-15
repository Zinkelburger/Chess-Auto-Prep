/// Aggregate result of a repertoire audit pass.
library;

import 'dart:convert';

import 'audit_finding.dart';

class AuditResult {
  final List<AuditFinding> findings;
  final int nodesChecked;
  final int ourMoveNodesChecked;
  final int opponentNodesChecked;
  final int leafNodesChecked;
  final int evalCacheHits;
  final int evalCacheMisses;
  final Duration elapsed;
  final DateTime? timestamp;

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
  }) : timestamp = timestamp ?? DateTime.now();

  static final empty = AuditResult(
    findings: [],
    nodesChecked: 0,
    ourMoveNodesChecked: 0,
    opponentNodesChecked: 0,
    leafNodesChecked: 0,
    evalCacheHits: 0,
    evalCacheMisses: 0,
    elapsed: Duration.zero,
  );

  int get totalEvalLookups => evalCacheHits + evalCacheMisses;

  double get evalCacheHitPercent =>
      totalEvalLookups > 0 ? (evalCacheHits / totalEvalLookups) * 100 : 0;

  int get mistakeCount =>
      findings.where((f) => f.type == AuditFindingType.mistake).length;

  int get inaccuracyCount =>
      findings.where((f) => f.type == AuditFindingType.inaccuracy).length;

  int get missingResponseCount =>
      findings.where((f) => f.type == AuditFindingType.missingResponse).length;

  int get weakPositionCount =>
      findings.where((f) => f.type == AuditFindingType.weakPosition).length;

  int get deadEndCount =>
      findings.where((f) => f.type == AuditFindingType.deadEnd).length;

  int get criticalCount =>
      findings.where((f) => f.severity == AuditSeverity.critical).length;

  int get warningCount =>
      findings.where((f) => f.severity == AuditSeverity.warning).length;

  int get infoCount =>
      findings.where((f) => f.severity == AuditSeverity.info).length;

  int get activeFindingCount => findings.where((f) => !f.dismissed).length;

  double get soundnessPercent {
    if (ourMoveNodesChecked == 0) return 100.0;
    final moveIssues = mistakeCount + inaccuracyCount + weakPositionCount;
    return ((ourMoveNodesChecked - moveIssues) / ourMoveNodesChecked) * 100;
  }

  /// Fraction of opponent-turn nodes where every common reply is covered.
  /// Dead ends are excluded -- they're leaf nodes counted in
  /// [leafNodesChecked], not [opponentNodesChecked].
  double get coveragePercent {
    if (opponentNodesChecked == 0) return 100.0;
    final nodesWithGaps = findings
        .where((f) => f.type == AuditFindingType.missingResponse)
        .map((f) => f.fen)
        .toSet()
        .length;
    final covered = opponentNodesChecked - nodesWithGaps;
    return (covered.clamp(0, opponentNodesChecked) / opponentNodesChecked) *
        100;
  }

  List<AuditFinding> get mistakes =>
      findings.where((f) => f.type == AuditFindingType.mistake).toList();

  List<AuditFinding> get inaccuracies =>
      findings.where((f) => f.type == AuditFindingType.inaccuracy).toList();

  List<AuditFinding> get missingResponses => findings
      .where((f) => f.type == AuditFindingType.missingResponse)
      .toList();

  List<AuditFinding> get weakPositions =>
      findings.where((f) => f.type == AuditFindingType.weakPosition).toList();

  List<AuditFinding> get deadEnds =>
      findings.where((f) => f.type == AuditFindingType.deadEnd).toList();

  // ── JSON serialization ────────────────────────────────────────────────

  String toJsonString() => jsonEncode(toJson());

  Map<String, dynamic> toJson() => {
        'version': 1,
        'timestamp': timestamp?.toIso8601String(),
        'nodesChecked': nodesChecked,
        'ourMoveNodesChecked': ourMoveNodesChecked,
        'opponentNodesChecked': opponentNodesChecked,
        'leafNodesChecked': leafNodesChecked,
        'evalCacheHits': evalCacheHits,
        'evalCacheMisses': evalCacheMisses,
        'elapsedMs': elapsed.inMilliseconds,
        'findings': findings.map((f) => f.toJson()).toList(),
      };

  factory AuditResult.fromJsonString(String s) =>
      AuditResult.fromJson(jsonDecode(s) as Map<String, dynamic>);

  factory AuditResult.fromJson(Map<String, dynamic> j) {
    final findings = (j['findings'] as List)
        .map((e) => AuditFinding.fromJson(e as Map<String, dynamic>))
        .toList();
    return AuditResult(
      findings: findings,
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

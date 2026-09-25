/// A read-only, point-in-time diagnosis. No finding authorizes a repair.
enum IntegrityKind { unfinished, unavailable, unsupported, dangling, derived }

final class IntegrityFinding {
  const IntegrityFinding(this.kind, this.path, this.detail);
  final IntegrityKind kind;
  final String path;
  final String detail;
}

final class IntegrityReport {
  IntegrityReport({
    required this.checkedAt,
    required Iterable<IntegrityFinding> findings,
    required Iterable<String> checked,
    required Iterable<String> skipped,
  }) : findings = List.unmodifiable(findings),
       checked = List.unmodifiable(checked),
       skipped = List.unmodifiable(skipped);
  final DateTime checkedAt;
  final List<IntegrityFinding> findings;
  final List<String> checked;
  final List<String> skipped;
  bool get clean => findings.isEmpty && skipped.isEmpty;
}

abstract interface class IntegrityReader {
  Future<IntegrityReport> read();
}

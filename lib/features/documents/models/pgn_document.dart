/// An observed persisted revision. Native identity is not a permanent document
/// identifier: every replacement gets a fresh observation, even with equal text.
class PgnRevision {
  const PgnRevision({
    required this.documentId,
    required this.nativeIdentity,
    required this.sha256,
  });
  final String documentId;
  final String nativeIdentity;
  final String sha256;

  @override
  bool operator ==(Object other) =>
      other is PgnRevision &&
      documentId == other.documentId &&
      nativeIdentity == other.nativeIdentity &&
      sha256 == other.sha256;
  @override
  int get hashCode => Object.hash(documentId, nativeIdentity, sha256);
}

class PgnSnapshot {
  const PgnSnapshot({
    required this.path,
    required this.revision,
    required this.content,
  });
  final String path;
  final PgnRevision revision;
  final String content;
}

sealed class PgnOpenResult {
  const PgnOpenResult();
}

final class PgnOpened extends PgnOpenResult {
  const PgnOpened(this.snapshot);
  final PgnSnapshot snapshot;
}

final class PgnMissing extends PgnOpenResult {
  const PgnMissing();
}

final class PgnReadFailed extends PgnOpenResult {
  const PgnReadFailed(this.error);
  final Object error;
}

sealed class PgnWriteResult {
  const PgnWriteResult();
}

final class PgnSaved extends PgnWriteResult {
  const PgnSaved({
    required this.before,
    required this.after,
    this.recoveryPath,
  });
  final PgnSnapshot? before;
  final PgnSnapshot after;
  final String? recoveryPath;
}

final class PgnConflict extends PgnWriteResult {
  const PgnConflict(this.current);
  final PgnSnapshot? current;
}

final class PgnNameCollision extends PgnWriteResult {
  const PgnNameCollision();
}

final class PgnWriteFailed extends PgnWriteResult {
  const PgnWriteFailed(this.error);
  final Object error;
}

/// The namespace may have changed. Do not retry a logical append: retain its
/// draft/baseline and reconcile [observed] first. Recovery artifacts are retained.
final class PgnWriteUncertain extends PgnWriteResult {
  const PgnWriteUncertain({
    required this.error,
    required this.before,
    required this.observed,
    this.installedRevision,
    this.recoveryPath,
  });
  final Object error;
  final PgnSnapshot? before;
  final PgnSnapshot? observed;

  /// Proven identity and bytes of this operation's staged artifact after it
  /// reached the destination. Equal decoded text alone is not installation
  /// proof. Null means callers must not infer provenance from [observed].
  final PgnRevision? installedRevision;
  final String? recoveryPath;
}

/// Quarantine is separate from replacement: its acknowledgement proves the
/// captured source is absent and its exact native object remains recoverable.
sealed class PgnQuarantineResult {
  const PgnQuarantineResult();
}

final class PgnQuarantined extends PgnQuarantineResult {
  const PgnQuarantined({
    required this.before,
    required this.retained,
    required this.recoveryPath,
  });
  final PgnSnapshot before;
  final PgnSnapshot retained;
  final String recoveryPath;
}

final class PgnQuarantineConflict extends PgnQuarantineResult {
  const PgnQuarantineConflict(this.current);
  final PgnSnapshot? current;
}

final class PgnQuarantineFailed extends PgnQuarantineResult {
  const PgnQuarantineFailed(this.error);
  final Object error;
}

/// The move may have happened. Keep both recovery locations; neither absence
/// nor equal decoded text authorizes retrying or reporting successful removal.
final class PgnQuarantineUncertain extends PgnQuarantineResult {
  const PgnQuarantineUncertain({
    required this.error,
    required this.before,
    required this.quarantinePath,
    required this.recoveryPath,
    required this.observedSource,
    required this.observedQuarantine,
  });
  final Object error;
  final PgnSnapshot before;
  final String quarantinePath;
  final String recoveryPath;
  final PgnSnapshot? observedSource;
  final PgnSnapshot? observedQuarantine;
}

import '../models/study_workspace_snapshot.dart';

class StudyRecoveryEntry {
  const StudyRecoveryEntry({
    required this.id,
    required this.revision,
    required this.updatedAt,
    required this.snapshot,
  });
  final String id;
  final String revision;
  final DateTime updatedAt;
  final StudyWorkspaceSnapshot snapshot;
}

class StudyRecoveryListing {
  StudyRecoveryListing(List<StudyRecoveryEntry> entries, {this.unreadable = 0})
    : entries = List.unmodifiable(entries);
  final List<StudyRecoveryEntry> entries;

  /// Unreadable/unknown records remain on disk, never replaced by an empty list.
  final int unreadable;
}

abstract interface class StudyRecoveryStore {
  /// Other live app instances are excluded. Reading never claims/discards work.
  Future<StudyRecoveryListing> list();

  /// Replace only this store instance's checkpoint, preserving its prior version
  /// on write failure. Clean checkpoints resolve that instance's prior draft.
  Future<void> write(StudyWorkspaceSnapshot snapshot);

  /// Resolve only the exact listed revision. Keeps bytes for explicit recovery.
  Future<void> resolve(StudyRecoveryEntry entry);
  Future<void> close();
}

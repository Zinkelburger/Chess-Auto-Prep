class WorkspaceRecoveryEntry<T> {
  const WorkspaceRecoveryEntry({
    required this.id,
    required this.revision,
    required this.updatedAt,
    required this.snapshot,
  });
  final String id;
  final String revision;
  final DateTime updatedAt;
  final T snapshot;
}

class WorkspaceRecoveryListing<T> {
  WorkspaceRecoveryListing(
    List<WorkspaceRecoveryEntry<T>> entries, {
    this.unreadable = 0,
  }) : entries = List.unmodifiable(entries);
  final List<WorkspaceRecoveryEntry<T>> entries;

  /// Unreadable/unknown records remain on disk, never replaced by an empty list.
  final int unreadable;
}

abstract interface class WorkspaceRecoveryStore<T> {
  /// Other live app instances are excluded. Reading never claims/discards work.
  Future<WorkspaceRecoveryListing<T>> list();

  /// Replace only this store instance's checkpoint, preserving its prior version
  /// on write failure. Clean checkpoints resolve that instance's prior draft.
  Future<void> write(T snapshot);

  /// Resolve only the exact listed revision. Keeps bytes for explicit recovery.
  Future<void> resolve(WorkspaceRecoveryEntry<T> entry);
  Future<void> close();
}

import 'package:chess_auto_prep/features/documents/repositories/workspace_recovery_store.dart';

class MemoryWorkspaceRecoveryStore<T> implements WorkspaceRecoveryStore<T> {
  final snapshots = <T>[];
  final entries = <WorkspaceRecoveryEntry<T>>[];
  final resolved = <String>[];
  Future<void> Function()? beforeWrite;
  Object? writeError;
  Object? readError;
  int unreadable = 0;
  @override
  Future<WorkspaceRecoveryListing<T>> list() async {
    if (readError != null) throw readError!;
    return WorkspaceRecoveryListing<T>(entries, unreadable: unreadable);
  }

  @override
  Future<void> write(T snapshot) async {
    await beforeWrite?.call();
    if (writeError != null) throw writeError!;
    snapshots.add(snapshot);
  }

  @override
  Future<void> resolve(WorkspaceRecoveryEntry<T> entry) async {
    resolved.add(entry.id);
    entries.remove(entry);
  }

  @override
  Future<void> close() async {}
}

import 'package:chess_auto_prep/features/studies/models/study_workspace_snapshot.dart';
import 'package:chess_auto_prep/features/studies/repositories/study_recovery_store.dart';

class MemoryStudyRecoveryStore implements StudyRecoveryStore {
  final snapshots = <StudyWorkspaceSnapshot>[];
  final entries = <StudyRecoveryEntry>[];
  final resolved = <String>[];
  Future<void> Function()? beforeWrite;
  Object? writeError;
  Object? readError;
  int unreadable = 0;
  @override
  Future<StudyRecoveryListing> list() async {
    if (readError != null) throw readError!;
    return StudyRecoveryListing(entries, unreadable: unreadable);
  }

  @override
  Future<void> write(StudyWorkspaceSnapshot snapshot) async {
    await beforeWrite?.call();
    if (writeError != null) throw writeError!;
    snapshots.add(snapshot);
  }

  @override
  Future<void> resolve(StudyRecoveryEntry entry) async {
    resolved.add(entry.id);
    entries.remove(entry);
  }

  @override
  Future<void> close() async {}
}

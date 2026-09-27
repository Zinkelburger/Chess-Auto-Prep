import 'repertoire_metadata.dart';
import 'repertoire_recovery_entry.dart';

enum CatalogAction { create, rename, moveToRecovery, restore }

/// Immutable presentation snapshot. Failed refreshes retain the last good list.
class RepertoireCatalogState {
  RepertoireCatalogState({
    List<RepertoireMetadata> repertoires = const [],
    List<RepertoireMetadata> studies = const [],
    List<RepertoireRecoveryEntry> recovery = const [],
    this.loading = false,
    this.loadError,
    this.action,
    this.actionError,
  }) : repertoires = List.unmodifiable(repertoires),
       studies = List.unmodifiable(studies),
       recovery = List.unmodifiable(recovery);

  final List<RepertoireMetadata> repertoires;
  final List<RepertoireMetadata> studies;
  final List<RepertoireRecoveryEntry> recovery;
  final bool loading;
  final Object? loadError;
  final CatalogAction? action;
  final Object? actionError;

  bool get busy => action != null;
}

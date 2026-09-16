import 'repertoire_metadata.dart';

enum CatalogAction { create, rename, moveToRecovery }

/// Immutable presentation snapshot. Failed refreshes retain the last good list.
class RepertoireCatalogState {
  RepertoireCatalogState({
    List<RepertoireMetadata> repertoires = const [],
    List<RepertoireMetadata> studies = const [],
    this.loading = false,
    this.loadError,
    this.action,
    this.actionError,
  }) : repertoires = List.unmodifiable(repertoires),
       studies = List.unmodifiable(studies);

  final List<RepertoireMetadata> repertoires;
  final List<RepertoireMetadata> studies;
  final bool loading;
  final Object? loadError;
  final CatalogAction? action;
  final Object? actionError;

  bool get busy => action != null;
}

import 'package:chess_auto_prep/app/builder_lifetime.dart';
import 'package:chess_auto_prep/features/repertoires/models/builder_workspace_snapshot.dart';
import 'package:chess_auto_prep/features/documents/repositories/workspace_recovery_store.dart';
import 'package:chess_auto_prep/features/repertoires/models/loaded_repertoire.dart';
import 'package:chess_auto_prep/features/repertoires/controllers/builder_workspace_controller.dart';
import 'package:chess_auto_prep/features/repertoires/repositories/repertoire_decoder.dart';
import 'package:chess_auto_prep/features/repertoires/repositories/repertoire_document_repository.dart';
import 'package:chess_auto_prep/infrastructure/documents/legacy_pgn_document_store.dart';
import 'package:chess_auto_prep/infrastructure/repertoires/document_repertoire_repository.dart';
import 'package:chess_auto_prep/infrastructure/repertoires/isolate_repertoire_decoder.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';

/// Legacy test fixtures install disposable storage. Capture it once here;
/// production controllers never resolve the global, even during later writes.
BuilderWorkspaceController testBuilderWorkspace({
  RepertoireDocumentRepository? documents,
  RepertoireDecoder decoder = const IsolateRepertoireDecoder(),
}) => BuilderWorkspaceController(
  checkpoint: () async {},
  documents: documents ?? testRepertoireDocuments(),
  decoder: decoder,
);

RepertoireDocumentRepository testRepertoireDocuments() =>
    DocumentRepertoireRepository(
      LegacyPgnDocumentStore(StorageFactory.instance),
    );

/// Script completion windows at the injected decoder boundary, without
/// test-only suspension hooks in the production session owner.
class GatedRepertoireDecoder implements RepertoireDecoder {
  GatedRepertoireDecoder({this.delegate = const IsolateRepertoireDecoder()});
  final RepertoireDecoder delegate;
  Future<void> Function()? beforeBuild;
  Future<void> Function()? afterBuild;
  @override
  Future<LoadedRepertoire> build(
    String? pgn, {
    required bool fallbackIsWhite,
  }) async {
    await beforeBuild?.call();
    final result = await delegate.build(pgn, fallbackIsWhite: fallbackIsWhite);
    await afterBuild?.call();
    return result;
  }
}

class MemoryBuilderRecoveryStore
    implements WorkspaceRecoveryStore<BuilderWorkspaceSnapshot> {
  BuilderWorkspaceSnapshot? snapshot;
  Object? failure;
  @override
  Future<WorkspaceRecoveryListing<BuilderWorkspaceSnapshot>> list() async =>
      WorkspaceRecoveryListing([]);
  @override
  Future<void> write(BuilderWorkspaceSnapshot value) async {
    if (failure != null) throw failure!;
    snapshot = value;
  }

  @override
  Future<void> resolve(
    WorkspaceRecoveryEntry<BuilderWorkspaceSnapshot> entry,
  ) async {}
  @override
  Future<void> close() async {}
}

BuilderLifetime testBuilderLifetime({
  RepertoireDocumentRepository? documents,
  RepertoireDecoder decoder = const IsolateRepertoireDecoder(),
}) => BuilderLifetime(
  documents: documents ?? testRepertoireDocuments(),
  decoder: decoder,
  store: MemoryBuilderRecoveryStore(),
);

import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../features/repertoires/controllers/builder_workspace_controller.dart';
import '../features/repertoires/models/builder_workspace_snapshot.dart';
import '../features/repertoires/repositories/repertoire_decoder.dart';
import '../features/repertoires/repositories/repertoire_document_repository.dart';
import '../features/documents/controllers/workspace_recovery_controller.dart';
import '../features/documents/repositories/workspace_recovery_store.dart';
import '../infrastructure/documents/file_workspace_recovery_store.dart';
import '../infrastructure/documents/builder_workspace_codec.dart';
import '../services/storage/app_paths.dart';

/// Application ownership, independent of Builder route/editor lifetimes.
class BuilderLifetime {
  BuilderLifetime({
    required RepertoireDocumentRepository documents,
    required RepertoireDecoder decoder,
    required WorkspaceRecoveryStore<BuilderWorkspaceSnapshot> store,
  }) {
    workspace = BuilderWorkspaceController(
      documents: documents,
      decoder: decoder,
    );
    recovery = WorkspaceRecoveryController<BuilderWorkspaceSnapshot>(
      workspace: workspace,
      capture: workspace.captureWorkspace,
      restoreSnapshot: workspace.restoreWorkspace,
      store: store,
    );
  }
  late final BuilderWorkspaceController workspace;
  late final WorkspaceRecoveryController<BuilderWorkspaceSnapshot> recovery;
  Future<void>? _shutdown;
  Future<void> flushForClose() async {
    // Checkpoint precedes waiting for a source writer: failures retain work.
    await recovery.flush();
    await workspace.document.flushDocumentForClose();
    await recovery.flush();
  }

  Future<void> shutdown() => _shutdown ??= _close();
  Future<void> _close() async {
    try {
      await flushForClose();
    } finally {
      try {
        await recovery.shutdown();
      } finally {
        recovery.dispose();
        workspace.dispose();
      }
    }
  }

  void dispose() => unawaited(shutdown().catchError((Object _) {}));
}

WorkspaceRecoveryStore<BuilderWorkspaceSnapshot> createBuilderRecoveryStore() =>
    FileWorkspaceRecoveryStore<BuilderWorkspaceSnapshot>(
      directory: () async => Directory(
        p.join((await AppPaths.supportDirectory()).path, 'builder-recovery-v1'),
      ),
      codec: const BuilderWorkspaceCodec(),
    );

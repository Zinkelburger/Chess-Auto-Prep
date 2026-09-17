import 'dart:async';
import 'dart:io';
import 'package:flutter/widgets.dart';
import '../features/documents/widgets/workspace_recovery_host.dart';
import '../features/documents/widgets/document_close_scope.dart';
import '../features/documents/controllers/document_close_coordinator.dart';
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
      checkpoint: () => recovery.flush(),
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
    while (true) {
      final revision = workspace.closeRevision;
      await recovery.flush();
      await workspace.settleActions();
      await workspace.document.flushDocumentForClose();
      await recovery.flush();
      if (revision == workspace.closeRevision) return;
    }
  }

  Future<void> shutdown() => _shutdown ??= _close();
  Future<void> _close() async {
    workspace.beginShutdown();
    try {
      await flushForClose();
    } finally {
      await workspace.settleActions();
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

/// Always mounted by the application, including before Builder is first opened.
class BuilderWorkspaceHost extends StatelessWidget {
  const BuilderWorkspaceHost({
    super.key,
    required this.lifetime,
    required this.onRestored,
    required this.child,
  });
  final BuilderLifetime lifetime;
  final VoidCallback onRestored;
  final Widget child;
  @override
  Widget build(BuildContext context) => DocumentCloseRegistration(
    revision: () => lifetime.workspace.closeRevision,
    prepare: () async {
      await lifetime.flushForClose();
      return DocumentCloseApproval(lifetime.workspace.closeRevision);
    },
    child: WorkspaceRecoveryHost<BuilderWorkspaceSnapshot>(
      recovery: lifetime.recovery,
      onRestored: onRestored,
      id: 'builder',
      workspaceName: 'Builder',
      title: (snapshot) => snapshot.drafts.firstOrNull?.title ?? 'Builder',
      path: (snapshot) =>
          snapshot.drafts.firstOrNull?.repertoire?.filePath ?? '',
      child: child,
    ),
  );
}

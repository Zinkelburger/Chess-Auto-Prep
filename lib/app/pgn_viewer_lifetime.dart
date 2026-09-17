import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import '../core/pgn_viewer_controller.dart';
import '../features/documents/controllers/workspace_recovery_controller.dart';
import '../features/documents/models/pgn_workspace_snapshot.dart';
import '../features/documents/repositories/desktop_fullscreen_port.dart';
import '../features/documents/repositories/pgn_collection_decoder.dart';
import '../features/documents/repositories/pgn_collection_filter.dart';
import '../features/documents/repositories/pgn_collection_repository.dart';
import '../features/documents/repositories/pgn_library_repository.dart';
import '../features/documents/repositories/viewer_preferences_repository.dart';
import '../features/documents/repositories/workspace_recovery_store.dart';
import '../features/documents/widgets/pgn_close_guard.dart';
import '../features/documents/widgets/pgn_copy_destination_dialog.dart';
import '../infrastructure/documents/file_workspace_recovery_store.dart';
import '../infrastructure/documents/pgn_workspace_codec.dart';
import '../services/game_analysis_controller.dart';
import '../services/storage/app_paths.dart';
import '../widgets/pgn_viewer_widget.dart';

/// App-lifetime wiring for the remaining legacy viewer host. The screen borrows
/// these owners; route visibility does not destroy its draft or recovery lease.
/// Retire this bridge as the reader/analysis interfaces migrate to the feature.
class PgnViewerLifetime {
  PgnViewerLifetime({
    required DesktopFullscreenPort window,
    int Function()? bulkDepth,
    required PgnCollectionRepository repository,
    required PgnCollectionDecoder collectionDecoder,
    required PgnCollectionFilter collectionFilter,
    required PgnLibraryRepository library,
    required ViewerPreferencesRepository preferences,
    required WorkspaceRecoveryStore<PgnWorkspaceSnapshot> store,
  }) {
    analysis = GameAnalysisController(bulkDepth: bulkDepth);
    controller = PgnViewerController(
      window: window,
      collectionRepository: repository,
      collectionDecoder: collectionDecoder,
      collectionFilter: collectionFilter,
      library: library,
      preferences: preferences,
      pgnWidgetController: reader,
      analysisController: analysis,
      isActive: () => !_disposed,
      schedulePostFrame: (callback) =>
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!_disposed) callback();
          }),
      onReclaimFocus: () => reclaimFocus?.call(),
    );
    unawaited(controller.initializePresentation());
    recovery = WorkspaceRecoveryController<PgnWorkspaceSnapshot>(
      workspace: controller,
      capture: () {
        reader.flushPendingComments();
        return controller.captureWorkspace();
      },
      restoreSnapshot: (snapshot) async {
        reader.flushPendingComments();
        await controller.restoreWorkspace(snapshot);
      },
      store: store,
    );
  }
  final reader = PgnViewerWidgetController();
  late final GameAnalysisController analysis;
  late final PgnViewerController controller;
  late final WorkspaceRecoveryController<PgnWorkspaceSnapshot> recovery;
  VoidCallback? reclaimFocus;
  bool _disposed = false;
  Future<void>? _shutdown;
  Object get closeRevision {
    reader.flushPendingComments();
    final state = controller.saveActions.state;
    return (
      controller.filePath,
      controller.collectionRevision,
      state.dirty,
      state.busy,
      state.uncertain,
      state.inspectionPath,
      state.retainedDrafts.length,
    );
  }

  Future<void> flushForClose() async {
    reader.flushPendingComments();
    await controller.flushPendingMetadata();
    await controller.saveSession();
    await recovery.flush();
  }

  Future<void> shutdown() => _shutdown ??= _close();
  Future<void> _close() async {
    reclaimFocus = null;
    reader.flushPendingComments();
    try {
      await controller.saveSession();
      await recovery.shutdown();
    } finally {
      _disposed = true;
      recovery.dispose();
      controller.dispose();
      analysis.dispose();
    }
  }

  void dispose() => unawaited(shutdown().catchError((Object _) {}));
}

WorkspaceRecoveryStore<PgnWorkspaceSnapshot> createPgnRecoveryStore() =>
    FileWorkspaceRecoveryStore<PgnWorkspaceSnapshot>(
      directory: () async => Directory(
        p.join(
          (await AppPaths.supportDirectory()).path,
          'pgn-viewer-recovery-v1',
        ),
      ),
      codec: const PgnWorkspaceCodec(),
    );

Future<String?> chooseViewerCopyDestination(
  BuildContext context,
  PgnViewerController controller, {
  String? name,
}) async {
  final path = controller.filePath;
  final directory = path == null
      ? (await AppPaths.documentsDirectory()).path
      : p.dirname(path);
  if (!context.mounted) return null;
  return showPgnCopyDestinationDialog(
    context,
    initialDirectory: directory,
    initialName:
        name ??
        (path == null
            ? 'games.pgn'
            : '${p.basenameWithoutExtension(path)} copy.pgn'),
    pickDirectory: (current) =>
        FilePicker.getDirectoryPath(initialDirectory: current),
  );
}

class PgnViewerCloseHost extends StatelessWidget {
  const PgnViewerCloseHost({
    super.key,
    required this.lifetime,
    required this.child,
  });
  final PgnViewerLifetime lifetime;
  final Widget child;
  @override
  Widget build(BuildContext context) => PgnCloseGuard(
    actions: lifetime.controller.saveActions,
    workspace: lifetime.controller,
    revision: () => lifetime.closeRevision,
    flush: lifetime.flushForClose,
    chooseCopyDestination: (context) =>
        chooseViewerCopyDestination(context, lifetime.controller),
    child: child,
  );
}

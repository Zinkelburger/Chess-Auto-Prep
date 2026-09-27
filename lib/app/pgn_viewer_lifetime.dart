import 'package:chess_auto_prep/services/engine/engine_lifecycle.dart';
import 'package:chess_auto_prep/services/engine/stockfish_pool.dart';
import '../features/documents/repositories/viewer_position_index_repository.dart';
import '../features/documents/repositories/viewer_opening_repository.dart';
import '../features/documents/repositories/viewer_solitaire_repository.dart';
import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import '../features/documents/controllers/viewer_document_controller.dart';
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

/// App-lifetime composition for the document-feature Viewer host. The screen borrows
/// these owners; route visibility does not destroy its draft or recovery lease.
/// The concrete reader/analysis bridge remains until their widgets and engine
/// lifecycle migrate; the feature host uses PgnViewerHandle/ViewerAnalysisPort.
class PgnViewerLifetime {
  PgnViewerLifetime({
    required ViewerPositionIndexRepository positionIndex,
    required ViewerOpeningRepository openings,
    required ViewerSolitaireRepository solitaireRepository,
    required DesktopFullscreenPort window,
    int Function()? bulkDepth,
    required StockfishPool pool,
    required EngineLifecycle lifecycle,
    required PgnCollectionRepository repository,
    required PgnCollectionDecoder collectionDecoder,
    required PgnCollectionFilter collectionFilter,
    required PgnLibraryRepository library,
    required ViewerPreferencesRepository preferences,
    required WorkspaceRecoveryStore<PgnWorkspaceSnapshot> store,
  }) {
    analysis = GameAnalysisController(
      bulkDepth: bulkDepth,
      pool: pool,
      lifecycle: lifecycle,
    );
    document = ViewerDocumentController(
      positionIndex: positionIndex,
      openings: openings,
      solitaireRepository: solitaireRepository,
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
    unawaited(document.presentation.initialize());
    recovery = WorkspaceRecoveryController<PgnWorkspaceSnapshot>(
      workspace: document.changes,
      capture: () {
        reader.flushPendingComments();
        return document.captureWorkspace();
      },
      restoreSnapshot: (snapshot) async {
        reader.flushPendingComments();
        await document.restoreWorkspace(snapshot);
      },
      store: store,
    );
  }
  final reader = PgnViewerWidgetController();
  late final GameAnalysisController analysis;
  late final ViewerDocumentController document;
  late final WorkspaceRecoveryController<PgnWorkspaceSnapshot> recovery;
  VoidCallback? reclaimFocus;
  bool _disposed = false;
  Future<void>? _shutdown;
  Object get closeRevision {
    reader.flushPendingComments();
    final state = document.editor.state;
    return (
      document.filePath,
      document.collection.contentRevision,
      state.dirty,
      state.busy,
      state.uncertain,
      state.inspectionPath,
      state.retainedDrafts.length,
    );
  }

  Future<void> flushForClose() async {
    reader.flushPendingComments();
    await document.editor.flushPendingMetadata();
    await document.reading.saveSession();
    await recovery.flush();
  }

  Future<void> shutdown() => _shutdown ??= _close();
  Future<void> _close() async {
    reclaimFocus = null;
    reader.flushPendingComments();
    try {
      await document.reading.saveSession();
      await recovery.shutdown();
    } finally {
      _disposed = true;
      recovery.dispose();
      document.dispose();
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
  ViewerDocumentController document, {
  String? name,
}) async {
  final path = document.filePath;
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
    actions: lifetime.document.editor,
    revision: () => lifetime.closeRevision,
    flush: lifetime.flushForClose,
    chooseCopyDestination: (context) =>
        chooseViewerCopyDestination(context, lifetime.document),
    child: child,
  );
}

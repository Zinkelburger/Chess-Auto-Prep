import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../features/settings/setting_rows.dart';
import '../ui/theme.dart';
import '../workspace/copy_name_dialog.dart';
import '../workspace/session_results.dart';
import 'app_exit.dart';
import 'basics.dart';
import 'exit_guard.dart';
import 'mode.dart';
import 'mode_wiring.dart';
import 'open_folder.dart';
import 'shell.dart';
import 'window_input.dart';
import 'workspace_requests.dart';
import 'workspace_wiring.dart';

/// The composition root: builds the parts in order — [Basics], the
/// document modes, the workspace, the cross-mode requests, the training
/// modes — hands them to the shell, and takes them down in reverse. How
/// each part is put together is its wiring's; this only orders them.
class ChessAutoPrepV2 extends StatefulWidget {
  const ChessAutoPrepV2({
    super.key,
    required this.documents,
    required this.support,
    required this.logFolder,
    required this.closeLog,
  });

  /// The user's Documents directory; repertoires live under it.
  final Directory documents;

  /// The app's own folder, where the engine is installed and the settings
  /// are kept.
  final Directory support;

  /// Where the log file is, for the settings page to open.
  final Directory logFolder;

  /// Flushes and closes the log file `main_v2` opened. Called on the way
  /// out, after the engines, so their last words reach the file.
  final Future<void> Function() closeLog;

  @override
  State<ChessAutoPrepV2> createState() => _ChessAutoPrepV2State();
}

class _ChessAutoPrepV2State extends State<ChessAutoPrepV2> {
  late final _basics = Basics(
    documents: widget.documents,
    support: widget.support,
  );
  late final DocumentModes _documents = wireDocumentModes(_basics);
  late final _workspace = WorkspaceWiring(_basics, _documents.library);

  /// The dialog on the way out is raised over the app, not over this widget,
  /// which sits above the navigator that shows it.
  final _navigator = GlobalKey<NavigatorState>();
  late final _exit = ExitGuard(
    saver: _basics.saver,
    question: DraftDialog(_navigator),
    saveCopy: _saveCopy,
  );
  late final _requests = WorkspaceRequests(
    session: _basics.session,
    library: _documents.library,
    studies: _documents.studies,
    viewer: _documents.viewer,
    games: _workspace.workspace.games,
    leaving: _exit,
    input: DialogInput(_navigator),
  );
  late final _training = TrainingWiring(
    _basics,
    workspace: _workspace.workspace,
    library: _documents.library,
    requests: _requests,
  );

  late final _quit = AppExit(
    guard: _exit,
    stopEngines: _basics.engines.dispose,
    closeLog: widget.closeLog,
  );
  late final AppLifecycleListener _lifecycle;

  /// Writes the words on screen beside the original, under a name the user
  /// gives, and answers the file it wrote. The question on the way out
  /// points at this because it is the one way out that keeps them.
  ///
  /// The copy does not take the session over: the user answered this while
  /// going somewhere else, and the document they are going to is the one
  /// they asked for.
  Future<String?> _saveCopy() async {
    final context = _navigator.currentContext;
    if (context == null) return null;
    final session = _basics.session;
    final name = await showCopyNameDialog(
      context,
      session.chapter?.name ?? 'Chapter',
    );
    if (name == null) return null;
    final written = await session.copyAside(name);
    return written is CopySaved ? written.name : null;
  }

  List<SettingGroup> _settingRows() => settingGroups(
    store: _basics.settings,
    coresAvailable: Platform.numberOfProcessors,
    account: _basics.account,
    openLogFolder: () => unawaited(openFolder(widget.logFolder)),
  );

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onExitRequested: _quit.leave,
      // Leaving the window is the moment a draft stops waiting for its
      // clock: whatever the user switches to might be the old app, opening
      // the same file.
      onInactive: _flushDraft,
      onHide: _flushDraft,
    );
    unawaited(_documents.library.refresh());
    unawaited(_start());
    unawaited(_training.modes.myGames.load());
  }

  Future<void> _start() async {
    await _basics.load();
    await _workspace.start();
  }

  void _flushDraft() => unawaited(_basics.saver.flush());

  @override
  void dispose() {
    _lifecycle.dispose();
    _requests.dispose();
    _training.dispose();
    _workspace.dispose();
    _documents.dispose();
    _basics.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Chess Auto Prep',
      navigatorKey: _navigator,
      theme: darkTheme(),
      debugShowCheckedModeBanner: false,
      home: Shell(
        requests: _requests,
        workspace: _workspace.workspace,
        documents: _documents,
        training: _training.modes,
        settingRows: _settingRows,
        settingsAlso: _basics.account,
      ),
    );
  }
}

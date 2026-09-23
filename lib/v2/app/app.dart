import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../features/settings/setting_rows.dart';
import '../ui/theme.dart';
import '../workspace/copy_name_dialog.dart';
import '../workspace/document_session.dart';
import '../workspace/session_results.dart';
import 'app_exit.dart';
import 'app_parts.dart';
import 'environment.dart';
import 'exit_guard.dart';
import 'open_folder.dart';
import 'shell.dart';
import 'window_input.dart';

/// The app on this machine: [AppParts] over the native environment, the
/// window's dialogs, and the way out.
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
  /// The dialogs are raised over the app, not over this widget, which sits
  /// above the navigator that shows them.
  final _navigator = GlobalKey<NavigatorState>();

  late final _parts = AppParts(
    AppEnvironment.native(documents: widget.documents, support: widget.support),
    question: DraftDialog(_navigator),
    input: DialogInput(_navigator),
    copyOnLeave: _copyOnLeave,
  );

  late final _quit = AppExit(
    guard: _parts.exit,
    stopEngines: _parts.env.stopEngines,
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
  Future<String?> _copyOnLeave(DocumentSession session) async {
    final context = _navigator.currentContext;
    if (context == null) return null;
    final name = await showCopyNameDialog(
      context,
      session.chapter?.name ?? 'Chapter',
    );
    if (name == null) return null;
    final written = await session.copyAside(name);
    return written is CopySaved ? written.name : null;
  }

  List<SettingGroup> _settingRows() => settingGroups(
    store: _parts.settings,
    coresAvailable: Platform.numberOfProcessors,
    account: _parts.account,
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
    unawaited(_parts.start());
  }

  void _flushDraft() => unawaited(_parts.saver.flush());

  @override
  void dispose() {
    _lifecycle.dispose();
    _parts.dispose();
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
        requests: _parts.requests,
        workspace: _parts.workspace,
        documents: _parts.documents,
        training: _parts.training,
        settingRows: _settingRows,
        settingsAlso: _parts.account,
      ),
    );
  }
}

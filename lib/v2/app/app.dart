import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';

import '../diagnostics/log.dart';
import '../features/settings/setting_rows.dart';
import '../ui/theme.dart';
import '../workspace/copy_name_dialog.dart';
import '../workspace/document_session.dart';
import '../workspace/session_results.dart';
import 'app_parts.dart';
import 'environment.dart';
import 'exit_guard.dart';
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
  /// gives, and answers what came of it; null when they gave none. The
  /// question on the way out points at this because it is the one way out
  /// that keeps them.
  ///
  /// The copy does not take the session over: the user answered this while
  /// going somewhere else, and the document they are going to is the one
  /// they asked for.
  Future<CopyResult?> _copyOnLeave(DocumentSession session) async {
    final context = _navigator.currentContext;
    if (context == null) return null;
    final name = await showCopyNameDialog(
      context,
      session.chapter?.name ?? 'Chapter',
    );
    if (name == null) return null;
    return session.copyAside(name);
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
        labs: _parts.labs,
        fullScreen: _parts.fullScreen,
        settingRows: _settingRows,
        settingsAlso: _parts.account,
      ),
    );
  }
}

/// The way out of the app: what the user typed reaches the disk — or they
/// say to close without it — then the engines are quit, the polite path
/// where a killed app relies on the pipes instead, and the log is closed
/// last so their final words are in it.
///
/// The window can be asked to close again while the first answer is still
/// being worked out: a second click on the close button, or one made while
/// the question about the unsaved words is up. Every request gets that one
/// answer, so the engines are never stopped under a dialog and the log is
/// never closed twice. A request that ended with the window staying open is
/// forgotten, so the next click asks again.
final class AppExit {
  AppExit({
    required ExitGuard guard,
    required Future<void> Function() stopEngines,
    required Future<void> Function() closeLog,
  }) : _guard = guard,
       _stopEngines = stopEngines,
       _closeLog = closeLog;

  final ExitGuard _guard;
  final Future<void> Function() _stopEngines;
  final Future<void> Function() _closeLog;

  /// The answer being worked out for a close that was asked for already.
  Future<AppExitResponse>? _leaving;

  /// Whether the window may close, with the engines and the log shut when
  /// it may.
  Future<AppExitResponse> leave() => _leaving ??= _leaveOnce();

  Future<AppExitResponse> _leaveOnce() async {
    if (!await _draftIsSettled()) {
      _leaving = null;
      return AppExitResponse.cancel;
    }
    await _stopEngines();
    log.i('exit');
    await _closeLog();
    return AppExitResponse.exit;
  }

  /// Words in a field the user never left are committed the way clicking
  /// elsewhere commits them, by taking the focus away; the focus change is
  /// applied in a microtask, so the edit is only made a turn later. Then the
  /// file is waited for, because the window closes next — but not for ever,
  /// which is [ExitGuard]'s job.
  Future<bool> _draftIsSettled() async {
    FocusManager.instance.primaryFocus?.unfocus();
    await Future<void>.delayed(Duration.zero);
    return _guard.mayClose();
  }
}

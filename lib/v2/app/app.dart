import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'dart:ui' show AppExitResponse;
import 'package:path/path.dart' as p;

import '../diagnostics/log.dart';
import '../engines/engine_supervisor.dart';
import '../features/library/library.dart';
import '../storage/chapter_files.dart';
import '../storage/pgn_file_store.dart';
import '../ui/theme.dart';
import '../workspace/document_saver.dart';
import '../workspace/document_session.dart';
import '../workspace/engine_analysis.dart';
import 'engine_launch.dart';
import 'shell.dart';

/// Builds the owners and hands them to the shell. This is the only place
/// that knows how the pieces fit together.
class ChessAutoPrepV2 extends StatefulWidget {
  const ChessAutoPrepV2({
    super.key,
    required this.documents,
    required this.support,
    required this.closeLog,
  });

  /// The user's Documents directory; repertoires live under it.
  final Directory documents;

  /// The app's own folder, where the engine is installed.
  final Directory support;

  /// Flushes and closes the log file `main_v2` opened. Called on the way
  /// out, after the engines, so their last words reach the file.
  final Future<void> Function() closeLog;

  @override
  State<ChessAutoPrepV2> createState() => _ChessAutoPrepV2State();
}

class _ChessAutoPrepV2State extends State<ChessAutoPrepV2> {
  late final _repertoires = p.join(widget.documents.path, 'repertoires');
  late final _store = PgnFileStore(
    documents: widget.documents,
    support: widget.support,
  );
  late final _saver = DocumentSaver(_store);
  late final _session = DocumentSession(_store, _saver);
  late final Library _library = Library(
    files: ChapterDirectory(Directory(_repertoires)),
    documents: _store,
    session: _session,
    saver: _saver,
    root: _repertoires,
  );
  final _engines = EngineSupervisor();
  late final _analysis = EngineAnalysis(
    _session,
    () => launchStockfish(support: widget.support, engines: _engines),
  );

  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onExitRequested: _leave);
    unawaited(_library.refresh());
    unawaited(_analysis.enable());
  }

  /// The way out: the draft reaches the disk, then the engines are quit —
  /// the polite path, where a killed app relies on the pipes instead — and
  /// the log is closed last so their final words are in it.
  Future<AppExitResponse> _leave() async {
    await _commitDraft();
    await _engines.dispose();
    log.i('exit');
    await widget.closeLog();
    return AppExitResponse.exit;
  }

  /// Words in a field the user never left are committed the way clicking
  /// elsewhere commits them, by taking the focus away; the focus change is
  /// applied in a microtask, so the edit is only made a turn later. Then the
  /// file is waited for, because the window closes next.
  Future<void> _commitDraft() async {
    FocusManager.instance.primaryFocus?.unfocus();
    await Future<void>.delayed(Duration.zero);
    await _saver.flush();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _analysis.dispose();
    _library.dispose();
    _session.dispose();
    _saver.dispose();
    unawaited(_engines.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Chess Auto Prep',
      theme: darkTheme(),
      debugShowCheckedModeBanner: false,
      home: Shell(
        library: _library,
        session: _session,
        saver: _saver,
        analysis: _analysis,
      ),
    );
  }
}

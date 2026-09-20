import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'dart:ui' show AppExitResponse;
import 'package:path/path.dart' as p;

import '../engines/engine_supervisor.dart';
import '../features/library/library.dart';
import '../storage/chapter_files.dart';
import '../ui/theme.dart';
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
  });

  /// The user's Documents directory; repertoires live under it.
  final Directory documents;

  /// The app's own folder, where the engine is installed.
  final Directory support;

  @override
  State<ChessAutoPrepV2> createState() => _ChessAutoPrepV2State();
}

class _ChessAutoPrepV2State extends State<ChessAutoPrepV2> {
  late final Library _library = Library(
    ChapterDirectory(Directory(p.join(widget.documents.path, 'repertoires'))),
  );
  final _session = DocumentSession();
  final _engines = EngineSupervisor();
  late final _analysis = EngineAnalysis(
    _session,
    () => launchStockfish(support: widget.support, engines: _engines),
  );

  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // Quits the engines before the window goes, the polite path; a killed
    // app relies on the pipes instead.
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        await _engines.dispose();
        return AppExitResponse.exit;
      },
    );
    unawaited(_library.refresh());
    unawaited(_analysis.enable());
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _analysis.dispose();
    _library.dispose();
    _session.dispose();
    unawaited(_engines.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Chess Auto Prep',
      theme: darkTheme(),
      debugShowCheckedModeBanner: false,
      home: Shell(library: _library, session: _session, analysis: _analysis),
    );
  }
}

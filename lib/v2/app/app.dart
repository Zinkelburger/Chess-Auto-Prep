import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../features/library/library.dart';
import '../storage/chapter_files.dart';
import '../ui/theme.dart';
import '../workspace/document_session.dart';
import 'shell.dart';

/// Builds the owners and hands them to the shell. This is the only place
/// that knows how the pieces fit together.
class ChessAutoPrepV2 extends StatefulWidget {
  const ChessAutoPrepV2({super.key, required this.documents});

  /// The user's Documents directory; repertoires live under it.
  final Directory documents;

  @override
  State<ChessAutoPrepV2> createState() => _ChessAutoPrepV2State();
}

class _ChessAutoPrepV2State extends State<ChessAutoPrepV2> {
  late final Library _library = Library(
    ChapterFiles(Directory(p.join(widget.documents.path, 'repertoires'))),
  );
  final _session = DocumentSession();

  @override
  void initState() {
    super.initState();
    unawaited(_library.refresh());
  }

  @override
  void dispose() {
    _library.dispose();
    _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Chess Auto Prep',
      theme: darkTheme(),
      debugShowCheckedModeBanner: false,
      home: Shell(library: _library, session: _session),
    );
  }
}

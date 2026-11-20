import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../storage/chapter_files.dart';
import '../../ui/attempting.dart';
import '../../ui/listening_state.dart';
import '../../ui/status_bar.dart';
import 'library.dart';
import 'library_messages.dart';
import 'library_state.dart';

/// Native file drops use the same guarded import as the file picker.
class PgnDropRegion extends StatefulWidget {
  const PgnDropRegion({
    super.key,
    required this.library,
    required this.onOpen,
    required this.child,
  });
  final Library library;
  final ValueChanged<ChapterRef> onOpen;
  final Widget child;
  @override
  State<PgnDropRegion> createState() => _PgnDropRegionState();
}

class _PgnDropRegionState extends State<PgnDropRegion>
    with Attempting<PgnDropRegion>, ListeningState<PgnDropRegion> {
  bool _hovering = false;

  @override
  Listenable listenableOf(PgnDropRegion widget) => widget.library;

  @override
  void changed() => setState(() {
    if (widget.library.busy) _hovering = false;
  });

  Future<void> _drop(DropDoneDetails detail) async {
    if (!mounted || busy) return;
    setState(() => _hovering = false);
    final paths = detail.files
        .map((file) => file.path)
        .where((path) => p.extension(path).toLowerCase() == '.pgn')
        .toSet();
    final library = widget.library;
    final say = StatusScope.of(context);
    if (paths.isEmpty) say('Drop a PGN file to import a repertoire.');
    const failed = 'The dropped PGN could not be imported.';
    await attempt('import dropped PGN files', () {
      return library.importPaths(paths, (path, result) {
        final message = libraryMessage(
          result,
          thing: 'repertoire',
          name: p.basenameWithoutExtension(path),
          failed: failed,
        );
        if (message != null) say(message);
        if (mounted && widget.library == library && result is LibraryAdded) {
          widget.onOpen(result.first);
        }
      });
    }, failure: failed);
    if (problem case final sentence?) say(sentence);
  }

  @override
  Widget build(BuildContext context) => DropTarget(
    enable: !busy && !widget.library.busy,
    onDragEntered: (_) => setState(() => _hovering = true),
    onDragExited: (_) => setState(() => _hovering = false),
    onDragDone: (detail) => unawaited(_drop(detail)),
    child: Stack(
      children: [
        widget.child,
        if (_hovering)
          Positioned.fill(
            child: IgnorePointer(
              child: ColoredBox(
                color: Theme.of(
                  context,
                ).colorScheme.primaryContainer.withValues(alpha: .9),
                child: const Center(
                  child: Text('Drop PGN files to import repertoires'),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

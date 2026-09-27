import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../storage/chapter_files.dart';
import '../../ui/error_bar.dart';
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

class _PgnDropRegionState extends State<PgnDropRegion> {
  bool _hovering = false;
  bool _importing = false;

  Future<void> _drop(DropDoneDetails detail) async {
    if (_importing) return;
    setState(() {
      _hovering = false;
      _importing = true;
    });
    final paths = detail.files
        .map((file) => file.path)
        .where((path) => p.extension(path).toLowerCase() == '.pgn')
        .toSet();
    if (paths.isEmpty) {
      StatusScope.of(context)('Drop a PGN file to import a repertoire.');
    }
    for (final path in paths) {
      if (!mounted) break;
      final result = await announce(
        context,
        widget.library.importPath(path),
        thing: 'repertoire',
        name: p.basenameWithoutExtension(path),
        failed: 'The dropped PGN could not be imported.',
      );
      if (mounted && result is LibraryAdded) widget.onOpen(result.first);
    }
    if (mounted) setState(() => _importing = false);
  }

  @override
  Widget build(BuildContext context) => DropTarget(
    enable: !_importing && !widget.library.busy,
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

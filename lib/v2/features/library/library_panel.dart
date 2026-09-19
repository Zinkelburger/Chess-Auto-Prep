import 'package:flutter/material.dart';

import '../../storage/chapter_files.dart';
import '../../ui/theme.dart';
import 'library.dart';

/// Chapters grouped by repertoire. Tapping one asks the host to open it.
class LibraryPanel extends StatelessWidget {
  const LibraryPanel({
    super.key,
    required this.library,
    required this.selected,
    required this.onOpen,
  });

  final Library library;
  final ChapterRef? selected;
  final ValueChanged<ChapterRef> onOpen;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: library,
      builder: (context, _) => switch (library.state) {
        LibraryLoading() => const Center(child: CircularProgressIndicator()),
        LibraryFailed(:final reason) => _Message(reason),
        LibraryReady(:final chapters) when chapters.isEmpty => const _Message(
          'No repertoires in Documents/repertoires',
        ),
        LibraryReady(:final chapters) => _ChapterList(
          chapters: chapters,
          selected: selected,
          onOpen: onOpen,
        ),
      },
    );
  }
}

class _ChapterList extends StatelessWidget {
  const _ChapterList({
    required this.chapters,
    required this.selected,
    required this.onOpen,
  });

  final List<ChapterRef> chapters;
  final ChapterRef? selected;
  final ValueChanged<ChapterRef> onOpen;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    String? repertoire;
    for (final chapter in chapters) {
      if (chapter.repertoire != repertoire) {
        repertoire = chapter.repertoire;
        rows.add(_RepertoireHeading(repertoire));
      }
      rows.add(
        ListTile(
          dense: true,
          title: Text(chapter.name),
          selected: chapter == selected,
          onTap: () => onOpen(chapter),
        ),
      );
    }
    return ListView(children: rows);
  }
}

class _RepertoireHeading extends StatelessWidget {
  const _RepertoireHeading(this.name);

  final String name;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.l, Space.l, Space.l, Space.xs),
      child: Text(
        name,
        style: Theme.of(context).textTheme.labelSmall,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(Space.l),
      child: Text(text, style: Theme.of(context).textTheme.bodySmall),
    );
  }
}

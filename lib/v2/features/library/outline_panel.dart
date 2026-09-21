import 'package:flutter/material.dart';

import '../../storage/chapter_files.dart';
import '../../ui/name_dialog.dart';
import '../../ui/search_field.dart';
import '../../ui/theme.dart';
import '../../workspace/chapter_commands.dart';
import '../../workspace/document_session.dart';
import '../../workspace/undo_notice.dart';
import 'chapter_outline.dart';
import 'library.dart';
import 'library_messages.dart';
import 'outline_rows.dart';

/// The chapters of the open repertoire and, under the open one, its lines.
///
/// Clicking a chapter opens it; clicking a line puts the cursor on its last
/// move. The line a line's `⋯` menu acts on is that line, never the cursor's.
class OutlinePanel extends StatefulWidget {
  const OutlinePanel({
    super.key,
    required this.outline,
    required this.library,
    required this.session,
    required this.onOpen,
  });

  final ChapterOutline outline;
  final Library library;
  final DocumentSession session;

  /// Opening a chapter is the host's, because it has to ask about a draft
  /// the file never took first.
  final ValueChanged<ChapterRef> onOpen;

  @override
  State<OutlinePanel> createState() => _OutlinePanelState();
}

class _OutlinePanelState extends State<OutlinePanel> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _newChapter() async {
    final into = widget.outline.repertoire;
    if (into == null) return;
    final name = await showNameDialog(
      context,
      title: 'New chapter',
      label: 'Chapter name',
      confirm: 'Create',
    );
    if (name == null || !mounted) return;
    await announce(
      context,
      widget.library.createChapter(into, name),
      thing: 'chapter',
      name: name,
      failed: 'Could not create the chapter.',
    );
  }

  Future<void> _rename(OutlineLine line) async {
    final name = await showNameDialog(
      context,
      title: 'Rename line',
      label: 'Line name',
      confirm: 'Rename',
      initial: line.name,
    );
    if (name == null || name == line.name || !mounted) return;
    // The chapter can have been edited while the dialog was up, and a game
    // index names a place in the file rather than a line: renaming by the
    // index alone could put the name on somebody else's line.
    if (widget.outline.nameOf(line.game) != line.name) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'That line changed while you were typing; '
            'nothing was renamed.',
          ),
        ),
      );
      return;
    }
    renameLine(widget.session, line.game, name);
  }

  /// Deletes the line and offers the way back, which is the undo the whole
  /// workspace shares: no question first, because the answer is one click
  /// away for as long as the notice is up.
  void _delete(OutlineLine line) {
    deleteLine(widget.session, line.game);
    showDeletionNotice(context, widget.session, 'Deleted 1 line.');
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.outline,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Toolbar(
            search: _search,
            onSearch: widget.outline.search,
            onCreate: widget.outline.repertoire == null ? null : _newChapter,
          ),
          Expanded(child: _body(context)),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    final outline = widget.outline;
    final chapters = outline.chapters;
    if (chapters.isEmpty) {
      return OutlineMessage(
        outline.query.trim().isEmpty
            ? 'No chapters yet\nCreate a chapter, then add your moves.'
            : 'No chapter or line matches "${outline.query}".',
      );
    }
    return ListView(
      children: [
        for (final chapter in chapters) ..._chapterRows(outline, chapter),
      ],
    );
  }

  List<Widget> _chapterRows(ChapterOutline outline, OutlineChapter chapter) {
    if (!chapter.open) {
      return [ChapterRow(chapter: chapter, onOpen: widget.onOpen)];
    }
    final lines = outline.lines;
    return [
      ChapterRow(chapter: chapter, onOpen: widget.onOpen),
      if (lines.isEmpty)
        const OutlineMessage('Empty — add lines to fill this chapter.'),
      for (final line in lines)
        LineRow(
          line: line,
          current: line.game == outline.currentLine,
          onTap: () => widget.session.goTo(line.at),
          actions: [
            MenuItemButton(
              onPressed: () => _rename(line),
              child: const Text('Rename line…'),
            ),
            MenuItemButton(
              onPressed: () => _delete(line),
              child: const Text('Delete line'),
            ),
            MenuItemButton(
              onPressed: _newChapter,
              child: const Text('New chapter…'),
            ),
          ],
        ),
    ];
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.search,
    required this.onSearch,
    required this.onCreate,
  });

  final TextEditingController search;
  final ValueChanged<String> onSearch;
  final VoidCallback? onCreate;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.m, Space.s, Space.s, Space.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Chapters',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
              IconButton(
                onPressed: onCreate,
                icon: const Icon(Icons.add, size: IconSize.action),
                tooltip: 'New chapter',
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          const SizedBox(height: Space.xs),
          SearchField(
            controller: search,
            hint: 'Find a chapter or line',
            onChanged: onSearch,
          ),
        ],
      ),
    );
  }
}

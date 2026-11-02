import 'package:flutter/material.dart';

import '../../storage/chapter_files.dart';
import '../../ui/search_field.dart';
import '../../ui/theme.dart';
import 'deleted_chapters_view.dart';
import 'library.dart';
import 'library_actions.dart';
import 'library_state.dart';
import 'repertoire_tile.dart';
import '../../ui/list_message.dart';
import '../../ui/app_icons.dart';
import '../../ui/tool_button.dart';
import '../../ui/pane_header.dart';

/// The repertoires, searchable, each opening to its chapters. Tapping a
/// chapter asks the host to open it in the workspace.
class LibraryPanel extends StatefulWidget {
  const LibraryPanel({
    super.key,
    required this.library,
    required this.selected,
    required this.onOpen,
    this.trailing,
  });

  final Library library;

  /// The chapter the workspace has open, highlighted in the list.
  final ChapterRef? selected;

  final ValueChanged<ChapterRef> onOpen;

  /// What sits in the toolbar's corner: the host's toggle for the pane.
  final Widget? trailing;

  @override
  State<LibraryPanel> createState() => _LibraryPanelState();
}

class _LibraryPanelState extends State<LibraryPanel> {
  final _search = TextEditingController();

  /// Which repertoires are open, by folder path. View state: it belongs to
  /// nobody but this panel, and a rename closing a row is no loss.
  final _expanded = <String>{};

  /// The deleted chapters are showing in place of the list.
  bool _showingDeleted = false;

  void _showDeleted(bool showing) {
    if (!mounted) return;
    setState(() => _showingDeleted = showing);
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _toggle(RepertoireFolder folder) {
    if (!mounted) return;
    setState(() {
      if (!_expanded.remove(folder.path)) _expanded.add(folder.path);
    });
  }

  Future<void> _newRepertoire() =>
      newRepertoire(context, widget.library, widget.onOpen);

  @override
  Widget build(BuildContext context) {
    if (_showingDeleted) {
      return DeletedChaptersView(
        library: widget.library,
        onBack: () => _showDeleted(false),
        trailing: widget.trailing,
      );
    }
    return ListenableBuilder(
      listenable: widget.library,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Toolbar(
            busy: widget.library.busy,
            // The empty list has its own button; one is enough.
            onCreate: switch (widget.library.state) {
              LibraryLoaded() when widget.library.repertoires.isNotEmpty =>
                _newRepertoire,
              _ => null,
            },
            search: _search,
            onSearch: widget.library.search,
            trailing: widget.trailing,
          ),
          Expanded(child: _body(context)),
          _DeletedLink(onPressed: () => _showDeleted(true)),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    final library = widget.library;
    return switch (library.state) {
      LibraryLoading() => const ListMessage.loading(
        'Reading repertoires…',
        inset: Space.m,
      ),
      LibraryLoadFailed() => ListMessage(
        'Could not read your repertoires.',
        action: OutlinedButton(
          onPressed: library.refresh,
          child: const Text('Try again'),
        ),
      ),
      LibraryLoaded() => _loaded(library),
    };
  }

  /// A folder the app was not allowed to read is named above the list. It is
  /// not in the list, and a repertoire that disappeared without a word is
  /// worse than one with a line saying why.
  Widget _loaded(Library library) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final folder in library.unreadable) _Unreadable(folder: folder),
      Expanded(child: _listed(library)),
    ],
  );

  Widget _listed(Library library) {
    if (library.repertoires.isEmpty) {
      return ListMessage(
        'No repertoires yet.',
        inset: Space.m,
        action: FilledButton.icon(
          onPressed: library.busy ? null : _newRepertoire,
          icon: const Icon(AppIcons.add, size: IconSize.action),
          label: const Text('New repertoire…'),
        ),
      );
    }
    if (library.visible.isEmpty) {
      return ListMessage('Nothing matches "${library.query}".');
    }
    return _list(library);
  }

  Widget _list(Library library) => ListView.builder(
    itemCount: library.visible.length,
    itemBuilder: (context, index) {
      final folder = library.visible[index];
      return RepertoireTile(
        library: library,
        folder: folder,
        expanded: _expanded.contains(folder.path),
        onToggle: () => _toggle(folder),
        selected: widget.selected,
        onOpen: widget.onOpen,
      );
    },
  );
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.busy,
    required this.onCreate,
    required this.search,
    required this.onSearch,
    required this.trailing,
  });

  final bool busy;

  /// Null while the list is empty or not read: the header's + then waits.
  final VoidCallback? onCreate;
  final TextEditingController search;
  final ValueChanged<String> onSearch;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      PaneHeader(
        'Your repertoires',
        actions: [
          if (onCreate case final create?)
            ToolButton(
              icon: AppIcons.add,
              tooltip: 'New repertoire…',
              onPressed: busy ? null : create,
            ),
        ],
        trailing: trailing,
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.m, Space.xs, Space.m, Space.s),
        child: SearchField(
          controller: search,
          hint: 'Search repertoires',
          onChanged: onSearch,
        ),
      ),
    ],
  );
}

/// The way to the deleted chapters, under the list where it is out of the
/// way until the user wants something back.
class _DeletedLink extends StatelessWidget {
  const _DeletedLink({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(Space.xs),
      child: Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: onPressed,
          icon: const Icon(AppIcons.restore, size: IconSize.action),
          label: const Text('Deleted chapters'),
        ),
      ),
    );
  }
}

class _Unreadable extends StatelessWidget {
  const _Unreadable({required this.folder});

  final UnreadableFolder folder;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.m, Space.xs, Space.m, Space.xs),
      child: Text(
        '${folder.name} could not be read: ${folder.detail}',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}

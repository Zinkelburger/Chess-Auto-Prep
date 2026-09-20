import 'package:flutter/material.dart';

import '../../storage/chapter_files.dart';
import '../../ui/search_field.dart';
import '../../ui/theme.dart';
import 'library.dart';
import 'library_messages.dart';
import 'new_repertoire_dialog.dart';
import 'repertoire_tile.dart';

/// The repertoires, searchable, each opening to its chapters. Tapping a
/// chapter asks the host to open it in the workspace.
class LibraryPanel extends StatefulWidget {
  const LibraryPanel({
    super.key,
    required this.library,
    required this.selected,
    required this.onOpen,
  });

  final Library library;

  /// The chapter the workspace has open, highlighted in the list.
  final ChapterRef? selected;

  final ValueChanged<ChapterRef> onOpen;

  @override
  State<LibraryPanel> createState() => _LibraryPanelState();
}

class _LibraryPanelState extends State<LibraryPanel> {
  final _search = TextEditingController();

  /// Which repertoires are open, by folder path. View state: it belongs to
  /// nobody but this panel, and a rename closing a row is no loss.
  final _expanded = <String>{};

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

  Future<void> _newRepertoire() async {
    final wanted = await showNewRepertoireDialog(context);
    if (wanted == null || !mounted) return;
    await announce(
      context,
      widget.library.createRepertoire(wanted.name, wanted.side),
      thing: 'repertoire',
      name: wanted.name,
      failed: 'Could not create the repertoire.',
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.library,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Toolbar(
            busy: widget.library.busy,
            onCreate: _newRepertoire,
            search: _search,
            onSearch: widget.library.search,
          ),
          Expanded(child: _body(context)),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    final library = widget.library;
    return switch (library.state) {
      LibraryLoading() => const Center(child: CircularProgressIndicator()),
      LibraryLoadFailed() => _Failure(onRetry: library.refresh),
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
      return const _Message(
        'No repertoires yet\nCreate a repertoire to get started.',
      );
    }
    if (library.visible.isEmpty) {
      return _Message('Nothing matches "${library.query}".');
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
  });

  final bool busy;
  final VoidCallback onCreate;
  final TextEditingController search;
  final ValueChanged<String> onSearch;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.m, Space.s, Space.m, Space.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Your repertoires',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
              TextButton.icon(
                onPressed: busy ? null : onCreate,
                icon: const Icon(Icons.add, size: IconSize.menu),
                label: const Text('New repertoire'),
              ),
            ],
          ),
          const SizedBox(height: Space.xs),
          SearchField(
            controller: search,
            hint: 'Search repertoires',
            onChanged: onSearch,
          ),
        ],
      ),
    );
  }
}

class _Failure extends StatelessWidget {
  const _Failure({required this.onRetry});

  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(Space.l),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Could not load repertoires. Please try again.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: Space.s),
          FilledButton(onPressed: onRetry, child: const Text('Retry')),
        ],
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

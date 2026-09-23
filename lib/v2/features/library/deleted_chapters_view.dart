import 'dart:async';

import 'package:flutter/material.dart';

import '../../storage/chapter_files.dart';
import '../../ui/name_dialog.dart';
import '../../ui/relative_time.dart';
import '../../ui/theme.dart';
import 'library.dart';
import 'library_messages.dart';
import 'library_state.dart';

/// The chapters the user deleted under the repertoire each came from, newest
/// first, each with `Restore`. It
/// takes the library panel's place until the user goes back.
///
/// The listing is view state: it is read when the view opens and again after
/// each restore, and nothing outside this view needs it.
class DeletedChaptersView extends StatefulWidget {
  const DeletedChaptersView({
    super.key,
    required this.library,
    required this.onBack,
    required this.onOpen,
    this.trailing,
  });

  final Library library;
  final VoidCallback onBack;

  /// Opens a chapter once it is back, from the confirmation's `Open`.
  final ValueChanged<ChapterRef> onOpen;

  /// What sits in the toolbar's corner: the host's toggle for the pane.
  final Widget? trailing;

  @override
  State<DeletedChaptersView> createState() => _DeletedChaptersViewState();
}

class _DeletedChaptersViewState extends State<DeletedChaptersView> {
  DeletedListing? _listing;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    final listing = await widget.library.deleted();
    if (!mounted) return;
    setState(() => _listing = listing);
  }

  /// Back under its old name; when a chapter of that name is there again,
  /// the user names this one, since nothing is ever replaced.
  Future<void> _restore(DeletedChapter chapter) async {
    final messenger = ScaffoldMessenger.of(context);
    var name = chapter.name;
    var result = await widget.library.restoreChapter(chapter);
    if (result is LibraryNameTaken && mounted) {
      final other = await showNameDialog(
        context,
        title: '"$name" is already in ${chapter.repertoire}',
        label: 'Restore as',
        confirm: 'Restore',
        initial: '$name (restored)',
      );
      if (other == null || !mounted) return;
      name = other;
      result = await widget.library.restoreChapter(chapter, name: name);
    }
    await _reload();
    final message = libraryMessage(
      result,
      thing: 'chapter',
      name: name,
      failed: 'Could not restore the chapter.',
    );
    final restored = ChapterRef.at(chapter.restoredAs(name));
    messenger.showSnackBar(
      SnackBar(
        content: Text(message ?? 'Restored "$name" to ${chapter.repertoire}.'),
        action: result is LibraryDone
            ? SnackBarAction(
                label: 'Open',
                onPressed: () => widget.onOpen(restored),
              )
            : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(onBack: widget.onBack, trailing: widget.trailing),
        Expanded(
          child: ListenableBuilder(
            listenable: widget.library,
            builder: (context, _) => _body(context),
          ),
        ),
      ],
    );
  }

  Widget _body(BuildContext context) => switch (_listing) {
    null => const Center(child: CircularProgressIndicator()),
    DeletedUnreadable() => _Unreadable(onRetry: _reload),
    DeletedChapters(:final chapters) when chapters.isEmpty => const _Message(
      'Nothing deleted\nChapters you delete can be restored here.',
    ),
    DeletedChapters(:final chapters) => ListView(
      children: [
        for (final MapEntry(key: repertoire, value: deleted) in _byRepertoire(
          chapters,
        ).entries) ...[
          _RepertoireHeading(repertoire),
          for (final chapter in deleted)
            _DeletedRow(
              chapter: chapter,
              busy: widget.library.busy,
              onRestore: () => _restore(chapter),
            ),
        ],
      ],
    ),
  };
}

/// [chapters] under the repertoire each came from, the repertoire with the
/// latest delete first, as the listing orders them.
Map<String, List<DeletedChapter>> _byRepertoire(List<DeletedChapter> chapters) {
  final groups = <String, List<DeletedChapter>>{};
  for (final chapter in chapters) {
    (groups[chapter.repertoire] ??= []).add(chapter);
  }
  return groups;
}

class _RepertoireHeading extends StatelessWidget {
  const _RepertoireHeading(this.name);

  final String name;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.m, Space.s, Space.m, 0),
      child: Text(
        name,
        style: Theme.of(context).textTheme.labelSmall,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onBack, required this.trailing});

  final VoidCallback onBack;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, Space.s, Space.m, Space.s),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, size: IconSize.action),
            tooltip: 'Back to repertoires',
            onPressed: onBack,
            visualDensity: VisualDensity.compact,
          ),
          Expanded(
            child: Text(
              'Deleted',
              style: Theme.of(context).textTheme.labelSmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class _DeletedRow extends StatelessWidget {
  const _DeletedRow({
    required this.chapter,
    required this.busy,
    required this.onRestore,
  });

  final DeletedChapter chapter;

  /// A catalog change is in flight, so a restore would be refused.
  final bool busy;

  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.m, Space.xs, Space.xs, Space.xs),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  chapter.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  relativeTime(chapter.deletedAt),
                  style: text.labelSmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: busy ? null : onRestore,
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
  }
}

class _Unreadable extends StatelessWidget {
  const _Unreadable({required this.onRetry});

  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(Space.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Could not read the deleted chapters. Please try again.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: Space.s),
          FilledButton(onPressed: onRetry, child: const Text('Retry')),
        ],
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

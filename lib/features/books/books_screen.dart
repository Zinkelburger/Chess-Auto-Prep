import 'dart:async';

import 'package:flutter/material.dart';

import '../../storage/book_list.dart';
import '../../storage/chapter_files.dart';
import '../../ui/app_icons.dart';
import '../../ui/confirm_dialog.dart';
import '../../ui/list_message.dart';
import '../../ui/list_row.dart';
import '../../ui/name_dialog.dart';
import '../../ui/problem_line.dart';
import '../../ui/row_actions.dart';
import '../../ui/search_field.dart';
import '../../ui/status_bar.dart';
import '../../ui/theme.dart';
import '../../ui/tool_button.dart';
import '../../workspace/book/books.dart';
import '../../workspace/book/repertoire_catalog.dart';

/// The Books mode: the user's books on the left, the one picked on the
/// right with every repertoire and its chapters to tick in or out. A book
/// is the set of lines being prepared — for one tournament, say — and the
/// one in use is what the explorer's Book, My games and the trainer read.
class BooksScreen extends StatelessWidget {
  const BooksScreen({
    super.key,
    required this.books,
    required this.catalog,
    required this.onOpenChapter,
    this.onAddRepertoire,
  });

  final Books books;

  /// The repertoires, as the builder lists them.
  final RepertoireCatalog catalog;

  /// Opens a chapter in the builder.
  final ValueChanged<ChapterRef> onOpenChapter;
  final VoidCallback? onAddRepertoire;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([books, catalog]),
    builder: (context, _) {
      final editing = books.editing;
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: listColumnWidth,
            child: _BookList(books: books, editing: editing),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: editing == null
                ? const SizedBox.shrink()
                : _BookEditor(
                    key: ValueKey(editing.id),
                    books: books,
                    book: editing,
                    catalog: catalog,
                    onOpenChapter: onOpenChapter,
                    onAddRepertoire: onAddRepertoire,
                  ),
          ),
        ],
      );
    },
  );
}

/// Asks a name for a new book and makes it. What went wrong goes to [say],
/// the window's status bar when not given.
Future<void> newBook(
  BuildContext context,
  Books books, {
  void Function(String sentence)? say,
}) async {
  await books.referencesSettled;
  if (!context.mounted) return;
  final status = say ?? StatusScope.of(context);
  final name = await showNameDialog(
    context,
    title: 'New opening book',
    label: 'Opening book name',
    confirm: 'Create',
  );
  if (name == null) return;
  await books.referencesSettled;
  if (!context.mounted) return;
  if (books.nameTaken(name)) {
    status('A book named "${name.trim()}" already exists.');
    return;
  }
  if (books.create(name) == null) {
    status(books.problem ?? 'Could not make the book.');
  }
}

Future<void> _rename(BuildContext context, Books books, Book book) async {
  await books.referencesSettled;
  if (!context.mounted) return;
  final say = StatusScope.of(context);
  final name = await showNameDialog(
    context,
    title: 'Rename opening book',
    label: 'Opening book name',
    initial: book.name,
    confirm: 'Rename',
  );
  if (name == null) return;
  await books.referencesSettled;
  if (!context.mounted) return;
  final current = books.books.where((entry) => entry.id == book.id).firstOrNull;
  if (current == null) {
    say(books.problem ?? 'That book is no longer available.');
    return;
  }
  if (name.trim() == current.name) return;
  if (books.nameTaken(name, except: current)) {
    say('A book named "${name.trim()}" already exists.');
    return;
  }
  books.rename(current, name);
  if (books.books.where((entry) => entry.id == book.id).firstOrNull?.name !=
      name.trim()) {
    say(books.problem ?? 'Could not rename the book.');
  }
}

Future<void> _delete(BuildContext context, Books books, Book book) async {
  await books.referencesSettled;
  if (!context.mounted) return;
  final say = StatusScope.of(context);
  final yes = await confirmAction(
    context,
    title: 'Delete opening book “${book.name}”?',
    message: 'Its repertoires and chapters stay where they are.',
    confirm: 'Delete',
  );
  if (!yes) return;
  await books.referencesSettled;
  if (!context.mounted) return;
  books.delete(book);
  if (books.books.any((entry) => entry.id == book.id)) {
    say(books.problem ?? 'Could not delete the book.');
  }
}

class _BookList extends StatelessWidget {
  const _BookList({required this.books, required this.editing});

  final Books books;
  final Book? editing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final empty = books.books.isEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.m, Space.s, Space.s, 0),
          child: SizedBox(
            height: listRowHeight,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Opening books',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                // The empty list has its own button; one is enough.
                if (!empty)
                  ToolButton(
                    icon: AppIcons.add,
                    tooltip: 'New opening book…',
                    onPressed: books.changingReferences
                        ? null
                        : () => unawaited(newBook(context, books)),
                  ),
              ],
            ),
          ),
        ),
        if (books.changingReferences)
          Padding(
            padding: const EdgeInsets.all(Space.m),
            child: Text(
              'Updating book chapters…',
              style: theme.textTheme.bodySmall,
            ),
          ),
        if (books.problem case final problem?)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.m),
            child: ProblemLine(
              problem,
              action: books.canRetry
                  ? OutlinedButton(
                      onPressed: books.changingReferences
                          ? null
                          : () => unawaited(books.retry()),
                      child: const Text('Retry save'),
                    )
                  : null,
            ),
          ),
        Expanded(child: _list(context)),
      ],
    );
  }

  /// The books, or the one sentence and button in their place.
  Widget _list(BuildContext context) {
    if (!books.loaded) {
      return const ListMessage.loading(
        'Reading opening books…',
        inset: Space.m,
      );
    }
    if (books.books.isEmpty) {
      return ListMessage(
        'No opening books yet.',
        inset: Space.m,
        action: FilledButton.icon(
          onPressed: books.changingReferences
              ? null
              : () => unawaited(newBook(context, books)),
          icon: const Icon(AppIcons.add, size: IconSize.action),
          label: const Text('New opening book…'),
        ),
      );
    }
    final inUse = Theme.of(context).textTheme.labelSmall;
    return ListView(
      children: [
        for (final book in books.books)
          ListRow(
            key: ValueKey(book.id),
            selected: book.id == editing?.id,
            onTap: () => books.edit(book),
            child: Row(
              children: [
                Expanded(
                  child: Text(book.name, overflow: TextOverflow.ellipsis),
                ),
                if (book.id == books.chosen?.id) Text('In use', style: inUse),
              ],
            ),
          ),
      ],
    );
  }
}

/// One book: its name, whether it is in use, and every repertoire with a
/// box to tick it in whole or chapter by chapter.
class _BookEditor extends StatefulWidget {
  const _BookEditor({
    super.key,
    required this.books,
    required this.book,
    required this.catalog,
    required this.onOpenChapter,
    this.onAddRepertoire,
  });

  final Books books;
  final Book book;
  final RepertoireCatalog catalog;
  final ValueChanged<ChapterRef> onOpenChapter;
  final VoidCallback? onAddRepertoire;

  @override
  State<_BookEditor> createState() => _BookEditorState();
}

class _BookEditorState extends State<_BookEditor> {
  final _search = TextEditingController();
  String _query = '';

  /// The repertoires opened to their chapters, by folder path. Those the
  /// book has in part start open.
  late final _open = <String>{
    for (final folder in widget.catalog.repertoires)
      if (widget.books.shareOf(widget.book, folder) == BookShare.some)
        folder.path,
  };

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _toggle(RepertoireFolder folder) {
    if (!mounted) return;
    setState(() {
      if (!_open.remove(folder.path)) _open.add(folder.path);
    });
  }

  void _typed(String words) {
    if (!mounted) return;
    setState(() => _query = words.trim().toLowerCase());
  }

  List<ChapterRef> _chapters(RepertoireFolder folder) => [
    for (final chapter in folder.chapters)
      if (!chapter.heading.draft) chapter,
  ];

  List<Widget> _rows() {
    final books = widget.books;
    final book = widget.book;
    final rows = <Widget>[];
    for (final folder in widget.catalog.repertoires) {
      final chapters = _chapters(folder);
      final folderMatches =
          _query.isEmpty || folder.name.toLowerCase().contains(_query);
      final matching = folderMatches
          ? chapters
          : [
              for (final chapter in chapters)
                if (chapter.name.toLowerCase().contains(_query)) chapter,
            ];
      if (!folderMatches && matching.isEmpty) continue;
      final open = _open.contains(folder.path) || !folderMatches;
      rows.add(
        _FolderRow(
          key: ValueKey(folder.path),
          folder: folder,
          share: books.shareOf(book, folder),
          chapters: chapters.where((c) => books.contains(book, c)).length,
          of: chapters.length,
          open: open,
          onToggle: () => _toggle(folder),
          onTick: books.changingReferences
              ? null
              : (inBook) => books.setRepertoire(book, folder, inBook),
        ),
      );
      if (!open) continue;
      for (final chapter in matching) {
        rows.add(
          _ChapterRow(
            key: ValueKey('${chapter.path}#${chapter.section}'),
            chapter: chapter,
            inBook: books.contains(book, chapter),
            onTick: books.changingReferences
                ? null
                : (inBook) => books.setChapter(book, folder, chapter, inBook),
            onOpen: () => widget.onOpenChapter(chapter),
          ),
        );
      }
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = _rows();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading(context),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Space.l,
            Space.m,
            Space.l,
            Space.s,
          ),
          child: SearchField(
            controller: _search,
            hint: 'Search repertoires and chapters',
            onChanged: _typed,
          ),
        ),
        Expanded(
          child: rows.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(Space.l),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.catalog.repertoires.isEmpty
                            ? 'Create or import a repertoire, then choose its chapters for this book.'
                            : 'Nothing matches "${_search.text.trim()}".',
                        style: theme.textTheme.bodySmall,
                      ),
                      if (widget.catalog.repertoires.isEmpty &&
                          widget.onAddRepertoire != null) ...[
                        const SizedBox(height: Space.m),
                        OutlinedButton(
                          onPressed: widget.onAddRepertoire,
                          child: const Text('Open repertoire builder'),
                        ),
                      ],
                    ],
                  ),
                )
              : ListView(children: rows),
        ),
      ],
    );
  }

  Widget _heading(BuildContext context) {
    final books = widget.books;
    final book = widget.book;
    final theme = Theme.of(context);
    final inUse = books.chosen?.id == book.id;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.l, Space.m, Space.s, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              book.name,
              style: theme.textTheme.titleMedium,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (inUse)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.m),
              child: Text('In use', style: theme.textTheme.bodySmall),
            )
          else
            // One per row, so never the filled one.
            OutlinedButton(
              onPressed: books.changingReferences
                  ? null
                  : () => books.activate(book),
              child: const Text('Use this book'),
            ),
          RowActions(
            tooltip: 'Book actions',
            children: [
              rowAction(
                'Rename…',
                () => unawaited(_rename(context, books, book)),
                busy: books.changingReferences,
                icon: AppIcons.edit,
              ),
              if (inUse)
                rowAction(
                  'Stop using',
                  () => books.activate(null),
                  busy: books.changingReferences,
                ),
              rowAction(
                'Delete…',
                () => unawaited(_delete(context, books, book)),
                busy: books.changingReferences,
                icon: AppIcons.delete,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FolderRow extends StatelessWidget {
  const _FolderRow({
    super.key,
    required this.folder,
    required this.share,
    required this.chapters,
    required this.of,
    required this.open,
    required this.onToggle,
    required this.onTick,
  });

  final RepertoireFolder folder;
  final BookShare share;

  /// How many of its [of] chapters the book has.
  final int chapters;
  final int of;
  final bool open;
  final VoidCallback onToggle;
  final ValueChanged<bool>? onTick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListRow(
      onTap: onToggle,
      height: bookRowHeight,
      padding: const EdgeInsets.only(left: Space.s, right: Space.l),
      child: Row(
        children: [
          Checkbox(
            tristate: true,
            value: switch (share) {
              BookShare.all => true,
              BookShare.some => null,
              BookShare.none => false,
            },
            // A part-ticked box ticks the rest.
            onChanged: onTick == null
                ? null
                : (_) => onTick!(share != BookShare.all),
          ),
          Icon(
            open ? AppIcons.expanded : AppIcons.collapsed,
            size: IconSize.menu,
          ),
          const SizedBox(width: Space.xs),
          Expanded(child: Text(folder.name, overflow: TextOverflow.ellipsis)),
          Text('$chapters of $of', style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _ChapterRow extends StatelessWidget {
  const _ChapterRow({
    super.key,
    required this.chapter,
    required this.inBook,
    required this.onTick,
    required this.onOpen,
  });

  final ChapterRef chapter;
  final bool inBook;
  final ValueChanged<bool>? onTick;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) => ListRow(
    onTap: onTick == null ? null : () => onTick!(!inBook),
    height: bookRowHeight,
    padding: const EdgeInsets.only(
      left: Space.s + bookChapterIndent,
      right: Space.s,
    ),
    child: Row(
      children: [
        Checkbox(
          value: inBook,
          onChanged: onTick == null ? null : (value) => onTick!(value ?? false),
        ),
        const SizedBox(width: Space.xs),
        Expanded(child: Text(chapter.name, overflow: TextOverflow.ellipsis)),
        ToolButton(
          icon: AppIcons.openElsewhere,
          tooltip: 'Open in builder',
          size: IconSize.menu,
          onPressed: onOpen,
        ),
      ],
    ),
  );
}

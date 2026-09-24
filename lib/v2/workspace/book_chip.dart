import 'dart:async';

import 'package:flutter/material.dart';

import '../storage/book_list.dart';
import '../ui/choice_dialog.dart';
import '../ui/error_bar.dart';
import '../ui/theme.dart';
import 'books.dart';

/// The one control wherever the book is read: the active book's name, which
/// switches to another book, and a pencil into the Books mode to edit them.
/// With no books yet the name goes straight to the Books mode.
class BookChip extends StatelessWidget {
  const BookChip({super.key, required this.books, required this.onEdit});

  final Books books;

  /// Shows the Books mode, at the active book.
  final VoidCallback onEdit;

  Future<void> _choose(BuildContext context) async {
    await books.referencesSettled;
    if (!context.mounted) return;
    final say = StatusScope.of(context);
    final chosen = await showChoiceDialog<Book>(
      context,
      title: 'Use book',
      options: books.books,
      label: (book) => book.name,
      hint: 'Type a book',
      empty: 'No books yet',
    );
    if (chosen == null) return;
    await books.referencesSettled;
    if (!context.mounted) return;
    final current = books.books
        .where((book) => book.id == chosen.id)
        .firstOrNull;
    if (current == null) {
      say(books.problem ?? 'That book is no longer available.');
      return;
    }
    books.activate(current);
    if (books.active?.id != current.id) {
      say(books.problem ?? 'Could not use the book.');
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: books,
    builder: (context, _) {
      final active = books.active;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Tooltip(
              message: books.changingReferences
                  ? 'Updating book chapters…'
                  : books.books.isEmpty
                  ? 'Make a book'
                  : 'Use another book',
              child: TextButton.icon(
                onPressed: books.changingReferences
                    ? null
                    : books.books.isEmpty
                    ? onEdit
                    : () => unawaited(_choose(context)),
                icon: const Icon(Icons.menu_book_outlined, size: IconSize.menu),
                label: Text(
                  books.changingReferences
                      ? 'Updating book chapters…'
                      : active?.name ?? 'No book set',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Edit books',
            iconSize: IconSize.menu,
            visualDensity: VisualDensity.compact,
            onPressed: onEdit,
            icon: const Icon(Icons.edit_outlined),
          ),
        ],
      );
    },
  );
}

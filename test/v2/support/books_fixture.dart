import 'dart:async';

import 'package:chess_auto_prep/v2/storage/book_file.dart';
import 'package:chess_auto_prep/v2/storage/book_list.dart';
import 'package:chess_auto_prep/v2/workspace/books.dart';

/// Books over the test repertoires folder, `/repertoires`, with one book in
/// use that has each of [repertoires] whole; none in use when it is null.
/// They are read at once, in a microtask.
Books booksWith([Set<String>? repertoires]) {
  final books = Books(
    store: MemoryBooks(
      repertoires == null
          ? BookList.empty
          : BookList(
              books: [
                Book(id: 'test', name: 'Test book', repertoires: repertoires),
              ],
              active: 'test',
            ),
    ),
    root: '/repertoires',
  );
  unawaited(books.load());
  return books;
}

// books.json written through the Books owner (lib/workspace/books.dart)
// under a fault at every effect: a repertoire put whole in a book, on a
// books.json this build writes whole (seedWithWrittenBooks). An edit made
// after a failed write is books_owner_faults_test.dart's. See
// fault_matrix.dart for the families.
@TestOn('linux')
library;

import 'package:chess_auto_prep/storage/book_list.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/workspace/books.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/faulty_disk/contracts.dart';
import '../../support/faulty_disk/fault_matrix.dart';
import '../../support/faulty_disk/scenario.dart';
import '../../support/faulty_disk/standard_commands.dart';
import '../../support/faulty_disk/stores.dart';
import '../../support/profile/standard_profile.dart';

/// The standard profile's book, as the owner has it now.
Book? _prep(Books books) =>
    books.books.where((book) => book.id == 'prep').firstOrNull;

/// Loads the books and puts all of KID in the book, in place of the KID
/// chapters it had. Nothing is edited when the books could not be read.
Future<Books> _edit(Stores s) async {
  final books = booksOwner(s);
  await books.load();
  final prep = _prep(books);
  if (prep == null) return books;
  final kid = RepertoireFolder(
    name: 'KID',
    path: s.profile.document('repertoires/KID'),
    modified: DateTime.utc(2026, 9, 29),
    chapters: const [],
  );
  books.setRepertoire(prep, kid, true);
  await books.settled;
  return books;
}

/// What the app offers: the owner's retry of the edits it holds, or, when
/// the books could not be read and nothing was edited, the edits again.
Future<Books> _retry(Stores s) async {
  final books = booksOwner(s);
  if (!books.canRetry) return _edit(s);
  await books.retry();
  return books;
}

/// Saved when the owner holds no problem and nothing to retry; a problem
/// may follow a write that landed, so it is unknown.
Verdict _saved(Books books) =>
    books.loaded && books.problem == null && !books.canRetry
    ? Verdict.committed
    : Verdict.unknown;

Future<String> _bookList(Stores s) => bookList(s);

const _books = StorageScenario<Stores, Books>(
  name: 'edit a book',
  seed: seedWithWrittenBooks,
  open: Stores.open,
  command: _edit,
  verdict: _saved,
  retry: _retry,
  firstRead: _bookList,
  probes: standardProbes,
);

void main() => faultMatrix(_books);

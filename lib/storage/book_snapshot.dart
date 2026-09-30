import 'book_list.dart';
import 'document_ref.dart';

/// Committed membership and the exact native file that supplied it. Memory
/// adapters have no native source; a missing native file has a source with
/// a null revision, so absence is never confused with an in-memory fixture.
final class BookSnapshot {
  BookSnapshot({required BookList value, this.source})
    : value = immutableBooks(value);

  final BookList value;
  final BookSource? source;
}

/// Proof for the fixed books.json participant in one configured profile.
final class BookSource {
  const BookSource({
    required this.supportPath,
    required this.canonicalSupport,
    required this.revision,
  });

  final String supportPath;
  final String canonicalSupport;
  final Revision? revision;
}

/// Membership cannot change behind its owner's revision or native proof.
BookList immutableBooks(BookList list) => BookList(
  active: list.active,
  books: List.unmodifiable([
    for (final book in list.books)
      Book(
        id: book.id,
        name: book.name,
        repertoires: Set.unmodifiable(book.repertoires),
        chapters: Set.unmodifiable(book.chapters),
      ),
  ]),
);

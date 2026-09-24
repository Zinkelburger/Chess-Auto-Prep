import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'book_list.dart';
import 'atomic_write.dart';

/// Where the books are kept. The filesystem is a real boundary, so this is
/// an interface: [BookFile] in the app, [MemoryBooks] in a test.
abstract interface class BookStore {
  /// The books as last written; [BookList.empty] when there is no file yet.
  /// Throws when there is one and it cannot be read.
  Future<BookList> read();

  Future<void> write(BookList books);
}

/// `books.json` in the app's support folder, written whole and atomically.
final class BookFile implements BookStore {
  BookFile(Directory support)
    : _file = File(p.join(support.path, 'books.json'));

  final File _file;

  @override
  Future<BookList> read() async {
    if (!await _file.exists()) return BookList.empty;
    return BookList.decode(await _file.readAsString());
  }

  @override
  Future<void> write(BookList books) async {
    await _file.parent.create(recursive: true);
    await replaceFile(_file.path, utf8.encode(books.encode()));
  }
}

/// Books kept in memory, for a test.
final class MemoryBooks implements BookStore {
  MemoryBooks([this.books = BookList.empty]);

  BookList books;

  @override
  Future<BookList> read() async => books;

  @override
  Future<void> write(BookList books) async => this.books = books;
}

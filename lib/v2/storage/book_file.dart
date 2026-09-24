import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'book_list.dart';
import 'atomic_write.dart';
import 'file_lock.dart';

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
  String? _baseline;
  bool _read = false;

  @override
  Future<BookList> read() async {
    _baseline = await _text();
    _read = true;
    return _baseline == null ? BookList.empty : BookList.decode(_baseline!);
  }

  @override
  Future<void> write(BookList books) async {
    await _file.parent.create(recursive: true);
    await withDirectoryLock(_file.parent, () async {
      final current = await _text();
      if ((!_read && current != null) || (_read && current != _baseline)) {
        throw StateError(
          'Books changed in another instance. Reload before editing.',
        );
      }
      final next = books.encode();
      await replaceFile(_file.path, utf8.encode(next));
      _baseline = next;
      _read = true;
    });
  }

  Future<String?> _text() async =>
      await _file.exists() ? _file.readAsString() : null;
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

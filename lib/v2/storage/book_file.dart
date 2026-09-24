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
  String? _attempted;
  bool _read = false;
  int _revision = 0;

  @override
  Future<BookList> read() async {
    final revision = ++_revision;
    final text = await _text();
    // An admitted writer keeps its original expected bytes. A late read
    // must not rebase that write onto another process's changes.
    if (revision == _revision) {
      _baseline = text;
      _attempted = null;
      _read = true;
    }
    return text == null ? BookList.empty : BookList.decode(text);
  }

  @override
  Future<void> write(BookList books) async {
    _revision++;
    final baseline = _baseline;
    final attempted = _attempted;
    final read = _read;
    await _file.parent.create(recursive: true);
    await withDirectoryLock(_file.parent, () async {
      final current = await _text();
      final next = books.encode();
      final knownAfter =
          current == next || (attempted != null && current == attempted);
      if (!knownAfter &&
          ((!read && current != null) || (read && current != baseline))) {
        throw StateError(
          'Books changed in another instance. Reload before editing.',
        );
      }
      // Keep both possible outcomes until publication is acknowledged. A
      // coalesced successor can follow the verified prior attempt's bytes,
      // while an unrelated version still conflicts. Republish to flush again.
      _baseline = current;
      _read = true;
      _attempted = next;
      await replaceFile(_file.path, utf8.encode(next));
      _baseline = next;
      _attempted = null;
      _revision++;
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

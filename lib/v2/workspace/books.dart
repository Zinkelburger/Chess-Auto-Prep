import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../diagnostics/log.dart';
import '../storage/book_file.dart';
import '../storage/book_list.dart';
import '../storage/chapter_files.dart';
import '../storage/pending_writes.dart';
import '../storage/pgn_document_store.dart' as documents;

/// The user's books and the one in use. Every reader of "the book" — the
/// explorer's Book, My games, the trainer — asks [includes]; the Books
/// mode makes and edits them.
///
/// Read once and written whole after every change, one write at a time,
/// the newest carried by the next. A file that cannot be read is not taken
/// for an empty one: [problem] says so and nothing is written over it.
final class Books extends ChangeNotifier {
  Books({
    required BookStore store,
    required String root,
    PendingWrites? pendingWrites,
  }) : pendingWrites = pendingWrites ?? PendingWrites(),
       _store = store,
       _root = root;

  final BookStore _store;
  final PendingWrites pendingWrites;

  /// The `repertoires` folder, absolute.
  final String _root;

  BookList _list = BookList.empty;
  bool _loaded = false;

  /// The file is there and could not be read: nothing is written over it.
  bool _unreadable = false;
  String? _problem;
  String? _editing;
  Future<void>? _writing;
  PendingObligation<void>? _saveObligation;
  bool _dirty = false;
  bool _disposed = false;
  int _revision = 0;
  bool _changingReferences = false;
  Completer<void>? _referenceWrite;

  Future<void> get referencesSettled async {
    while (_referenceWrite != null) {
      await _referenceWrite!.future;
    }
  }

  /// A structural document save is settling the book snapshot it changes.
  bool get changingReferences => _changingReferences;

  List<Book> get books => _list.books;

  /// The book everything reads, or null while none is set.
  Book? get active => _list.activeBook;

  bool get loaded => _loaded;

  /// Why the books could not be read or written, or null.
  String? get problem => _problem;

  /// The book the Books mode has open: the one asked for, else the active
  /// one, else the first.
  Book? get editing =>
      _list.byId(_editing) ?? active ?? _list.books.firstOrNull;

  Future<void> load() async {
    if (_disposed || _dirty || canRetry || _changingReferences) return;
    final revision = ++_revision;
    try {
      final list = await _store.read();
      if (_disposed || revision != _revision || canRetry) return;
      _list = list;
      _problem = null;
      _unreadable = false;
    } on Object catch (error) {
      if (_disposed || revision != _revision || canRetry) return;
      log.w('read the books', error);
      _unreadable = true;
      _problem = 'Your books could not be read, so none are shown.';
    }
    _loaded = true;
    _notify();
  }

  /// Whether [ref] is in the active book.
  bool includes(ChapterRef ref) => contains(active, ref);

  /// Whether [ref] is in [book].
  bool contains(Book? book, ChapterRef ref) {
    final path = bookPath(_root, ref.path);
    return book != null && path != null && book.includes(path, ref.section);
  }

  /// How much of [folder] [book] has: all of it, some or none.
  BookShare shareOf(Book book, RepertoireFolder folder) {
    final path = bookPath(_root, folder.path);
    if (path != null && book.repertoires.contains(path)) return BookShare.all;
    final chapters = folder.chapters.where((c) => !c.heading.draft).toList();
    final inBook = chapters.where((c) => contains(book, c)).length;
    if (inBook == 0) return BookShare.none;
    return inBook == chapters.length ? BookShare.all : BookShare.some;
  }

  /// Opens [book] in the Books mode.
  void edit(Book book) {
    if (_editing == book.id) return;
    _editing = book.id;
    _notify();
  }

  /// A new, empty book called [name], open for editing; the active one when
  /// none was. Null when the books could not be read.
  Book? create(String name) {
    if (!_writable) return null;
    final book = Book(id: _newId(), name: name.trim());
    _editing = book.id;
    _save(
      BookList(books: [..._list.books, book], active: _list.active ?? book.id),
    );
    return book;
  }

  /// Whether another book than [except] is already called [name].
  bool nameTaken(String name, {Book? except}) => _list.books.any(
    (book) =>
        book.id != except?.id &&
        book.name.toLowerCase() == name.trim().toLowerCase(),
  );

  void rename(Book book, String name) {
    final current = _list.byId(book.id);
    if (current != null) _replace(current.copyWith(name: name.trim()));
  }

  void delete(Book book) {
    if (!_writable) return;
    if (_editing == book.id) _editing = null;
    _save(
      BookList(
        books: [
          for (final b in _list.books)
            if (b.id != book.id) b,
        ],
        active: _list.active == book.id ? null : _list.active,
      ),
    );
  }

  /// Makes [book] the one everything reads; null sets none.
  void activate(Book? book) {
    if (book?.id == _list.active) return;
    _save(BookList(books: _list.books, active: book?.id));
  }

  /// Puts all of [folder] in [book] or takes all of it out.
  void setRepertoire(Book book, RepertoireFolder folder, bool inBook) {
    final path = bookPath(_root, folder.path);
    if (path == null) return;
    // A folder selection covers all descendants, just as Book.includes does.
    // Remove redundant nested selections when adding it, and every explicit
    // descendant when removing it. A similarly named sibling stays untouched.
    bool inside(String selection) =>
        selection == path || p.posix.isWithin(path, selection);
    final repertoires = {
      for (final selected in book.repertoires)
        if (!inside(selected)) selected,
      if (inBook) path,
    };
    final chapters = {
      for (final chapter in book.chapters)
        if (!inside(chapter.path)) chapter,
    };
    _replace(book.copyWith(repertoires: repertoires, chapters: chapters));
  }

  /// Puts [chapter] of [folder] in [book] or takes it out. Taking one out of
  /// a repertoire the book has whole leaves the book the others one by one.
  void setChapter(
    Book book,
    RepertoireFolder folder,
    ChapterRef chapter,
    bool inBook,
  ) {
    final folderPath = bookPath(_root, folder.path);
    final path = bookPath(_root, chapter.path);
    if (folderPath == null || path == null) return;
    final repertoires = book.repertoires.toSet();
    final chapters = book.chapters.toSet();
    if (!inBook && repertoires.remove(folderPath)) {
      for (final other in folder.chapters) {
        if (other == chapter || other.heading.draft) continue;
        if (bookPath(_root, other.path) case final otherPath?) {
          chapters.add(BookChapter(otherPath, other.section));
        }
      }
    }
    final own = BookChapter(path, chapter.section);
    if (inBook) {
      chapters.add(own);
    } else {
      chapters
        ..remove(own)
        ..remove(BookChapter(path, null));
    }
    _replace(book.copyWith(repertoires: repertoires, chapters: chapters));
  }

  /// A chapter file was renamed or moved from [from] to [to]: every book
  /// that had it has it where it went.
  void movedFile(String from, String to) {
    final was = bookPath(_root, from);
    final now = bookPath(_root, to);
    if (was == null || now == null) return;
    _rewrite(
      (book) => book.copyWith(
        chapters: {
          for (final chapter in book.chapters)
            chapter.path == was ? BookChapter(now, chapter.section) : chapter,
        },
      ),
    );
  }

  /// A repertoire folder was renamed from [from] to [to].
  void movedFolder(String from, String to) {
    final was = bookPath(_root, from);
    final now = bookPath(_root, to);
    if (was == null || now == null) return;
    String moved(String path) => path == was
        ? now
        : (path.startsWith('$was/')
              ? '$now${path.substring(was.length)}'
              : path);
    _rewrite(
      (book) => book.copyWith(
        repertoires: {for (final folder in book.repertoires) moved(folder)},
        chapters: {
          for (final chapter in book.chapters)
            BookChapter(moved(chapter.path), chapter.section),
        },
      ),
    );
  }

  /// The chapter [from] of the course file at [path] is now called [to].
  void renamedSection(String path, String from, String to) {
    final at = bookPath(_root, path);
    if (at == null) return;
    _rewrite(
      (book) => book.copyWith(
        chapters: {
          for (final chapter in book.chapters)
            chapter.path == at && chapter.section == from
                ? BookChapter(at, to)
                : chapter,
        },
      ),
    );
  }

  void _rewrite(Book Function(Book book) change) {
    final books = [for (final book in _list.books) change(book)];
    _save(BookList(books: books, active: _list.active));
  }

  void _replace(Book book) => _save(
    BookList(
      books: [
        for (final b in _list.books)
          if (b.id == book.id) book else b,
      ],
      active: _list.active,
    ),
  );

  bool get _writable =>
      !_disposed && _loaded && !_unreadable && !_changingReferences;

  /// Shows [list] at once and writes it. Nothing is written over a file
  /// that could not be read.
  void _save(BookList list) {
    if (!_writable) {
      _notify();
      return;
    }
    _revision++;
    _list = list;
    _dirty = true;
    _notify();
    unawaited(_persist());
  }

  /// Serializes an essential reference change with accepted book edits before
  /// the storage domain is acquired. New book edits wait for the committed
  /// snapshot; failures preserve the document command for its owner's retry.
  Future<documents.SaveResult> saveReferences(
    Future<documents.SaveResult> Function() save,
  ) async {
    if (_changingReferences || _disposed) {
      return const documents.IoFailure(
        'A book reference change is still pending.',
      );
    }
    _changingReferences = true;
    final completion = _referenceWrite = Completer<void>();
    _revision++;
    _notify();
    try {
      await pendingWrites.settleFor(_store);
      if (!canRetry && (!_loaded || _unreadable)) await _readReferences();
      if (_unreadable || canRetry) {
        return const documents.IoFailure(
          'Save or recover your books before renaming a chapter.',
        );
      }
      final documents.SaveResult result;
      try {
        result = await save();
      } finally {
        // A lost acknowledgement may leave intent. Read through recovery
        // before allowing the book snapshot to be edited again.
        await _readReferences();
      }
      return result;
    } finally {
      _changingReferences = false;
      _referenceWrite = null;
      completion.complete();
      _notify();
    }
  }

  Future<void> _readReferences() async {
    _loaded = true;
    try {
      _list = await _store.read();
      _problem = null;
      _unreadable = false;
    } on Object catch (error) {
      _unreadable = true;
      _problem = 'Your book references need recovery: $error';
      log.w('read committed book references', error);
    }
  }

  /// A failed snapshot stays owned by the app, including after disposal.
  bool get canRetry => _saveObligation?.committed == false;

  Future<void> retry() => _disposed || !canRetry ? Future.value() : _persist();

  Future<void> _persist() {
    if (!canRetry) {
      _saveObligation = pendingWrites.accept<void>(
        resource: _store,
        label: 'Books',
        work: () => _writing ??= _writeNewest(),
        problem: (_) => _problem,
      );
    }
    return _saveObligation!.run();
  }

  Future<void> _writeNewest() async {
    _dirty = true;
    try {
      while (_dirty) {
        _dirty = false;
        await _store.write(_list);
      }
      if (_problem != null) {
        _problem = null;
        _notify();
      }
    } on Object catch (error) {
      log.w('write the books', error);
      _problem = 'Your books could not be saved: $error';
      _notify();
    } finally {
      _writing = null;
    }
  }

  /// Waits for the write in flight, for a test.
  Future<void> get settled => _writing ?? Future.value();

  static int _made = 0;

  static String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
      '${(_made++).toRadixString(36)}';

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// How much of a repertoire a book has.
enum BookShare { all, some, none }

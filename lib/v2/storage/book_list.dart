import 'dart:convert';

import 'package:path/path.dart' as p;

/// A book: a named set of the user's repertoires and chapters, the lines
/// they are preparing — for one tournament, say. A repertoire in it counts
/// whole, chapters added to it later included; a chapter counts on its own.
/// Each chapter already says which side it is for, so one book holds both
/// colours and a reader takes the side it wants.
///
/// Paths are relative to the repertoires folder, with `/` between the
/// parts, so the file reads the same on every machine.
final class Book {
  const Book({
    required this.id,
    required this.name,
    this.repertoires = const {},
    this.chapters = const {},
  });

  final String id;
  final String name;

  /// The folders under `repertoires/` that count whole.
  final Set<String> repertoires;

  /// The chapters that count on their own: a file, or one chapter of a
  /// course file by its `[ChapterName]`.
  final Set<BookChapter> chapters;

  bool get isEmpty => repertoires.isEmpty && chapters.isEmpty;

  /// Whether the chapter [section] of the file at [path] is in the book:
  /// its folder is, the chapter is, or its whole file is.
  bool includes(String path, String? section) =>
      repertoires.any(
        (folder) => folder == path || p.posix.isWithin(folder, path),
      ) ||
      chapters.contains(BookChapter(path, section)) ||
      (section != null && chapters.contains(BookChapter(path, null)));

  Book copyWith({
    String? name,
    Set<String>? repertoires,
    Set<BookChapter>? chapters,
  }) => Book(
    id: id,
    name: name ?? this.name,
    repertoires: repertoires ?? this.repertoires,
    chapters: chapters ?? this.chapters,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'repertoires': repertoires.toList()..sort(),
    'chapters': [
      for (final chapter in chapters.toList()..sort(BookChapter.order))
        chapter.toJson(),
    ],
  };

  /// A book read back, or null when [json] is not one.
  static Book? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final id = json['id'];
    final name = json['name'];
    if (id is! String || name is! String) return null;
    final folders = json['repertoires'];
    final chapters = json['chapters'];
    return Book(
      id: id,
      name: name,
      repertoires: {
        if (folders is List)
          for (final folder in folders)
            if (folder is String) folder,
      },
      chapters: {
        if (chapters is List)
          for (final chapter in chapters)
            if (BookChapter.fromJson(chapter) case final read?) read,
      },
    );
  }
}

/// A chapter in a book: the file at [path], or its games that carry the
/// `[ChapterName]` [section].
final class BookChapter {
  const BookChapter(this.path, this.section);

  /// Relative to the repertoires folder, `/` between the parts.
  final String path;
  final String? section;

  static int order(BookChapter a, BookChapter b) {
    final byPath = a.path.compareTo(b.path);
    return byPath != 0 ? byPath : (a.section ?? '').compareTo(b.section ?? '');
  }

  Map<String, Object?> toJson() => {'path': path, 'section': section};

  static BookChapter? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final path = json['path'];
    final section = json['section'];
    if (path is! String || (section != null && section is! String)) {
      return null;
    }
    return BookChapter(path, section as String?);
  }

  @override
  bool operator ==(Object other) =>
      other is BookChapter && other.path == path && other.section == section;

  @override
  int get hashCode => Object.hash(path, section);
}

/// Every book, and the one in use: what `books.json` holds.
final class BookList {
  const BookList({this.books = const [], this.active});

  static const empty = BookList();

  final List<Book> books;

  /// The id of the book everything reads — the explorer's Book, My games,
  /// the trainer — or null while none is set.
  final String? active;

  Book? get activeBook => byId(active);

  Book? byId(String? id) =>
      id == null ? null : books.where((book) => book.id == id).firstOrNull;

  String encode() => const JsonEncoder.withIndent('  ').convert({
    'version': 1,
    'active': active,
    'books': [for (final book in books) book.toJson()],
  });

  /// The list [text] holds. Throws [FormatException] when it is not one, so
  /// a file that cannot be read is never taken for an empty one.
  static BookList decode(String text) {
    final json = jsonDecode(text);
    if (json is! Map<String, Object?> || json['books'] is! List) {
      throw const FormatException('not a list of books');
    }
    final books = [
      for (final book in json['books']! as List)
        if (Book.fromJson(book) case final read?) read,
    ];
    final active = json['active'];
    return BookList(
      books: books,
      active: active is String && books.any((b) => b.id == active)
          ? active
          : null,
    );
  }
}

/// The folder of the chapter file at [path], both relative.
String folderOf(String path) => p.posix.dirname(path);

/// [path] under [root] as a book writes it: relative, `/` between the parts.
/// Null when it is not under [root].
String? bookPath(String root, String path) {
  if (!p.isWithin(root, path)) return null;
  return p.posix.joinAll(p.split(p.relative(path, from: root)));
}

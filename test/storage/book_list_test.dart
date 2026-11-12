import 'package:chess_auto_prep/storage/book_list.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('a book', () {
    test('is empty until it holds a repertoire or a chapter', () {
      const blank = Book(id: 'a', name: 'Open');
      expect(blank.all, isFalse);
      expect(blank.isEmpty, isTrue);
      expect(blank.includes('KID/Main.pgn', null), isFalse);
      expect(
        const Book(id: 'a', name: 'Open', repertoires: {'KID'}).isEmpty,
        isFalse,
      );
      expect(
        Book(
          id: 'a',
          name: 'Open',
          chapters: {const BookChapter('KID/Main.pgn', null)},
        ).isEmpty,
        isFalse,
      );
      expect(Book.everything.isEmpty, isFalse);
    });

    test('holds a file\'s chapters when it holds the whole file, not the '
        'other way round', () {
      final whole = Book(
        id: 'a',
        name: 'Open',
        chapters: {const BookChapter('Course.pgn', null)},
      );
      expect(whole.includes('Course.pgn', 'Najdorf'), isTrue);
      final one = Book(
        id: 'a',
        name: 'Open',
        chapters: {const BookChapter('Course.pgn', 'Najdorf')},
      );
      expect(one.includes('Course.pgn', 'Najdorf'), isTrue);
      expect(one.includes('Course.pgn', 'Dragon'), isFalse);
      expect(one.includes('Course.pgn', null), isFalse);
    });

    test('writes its chapters in path order, then by chapter', () {
      final book = Book(
        id: 'a',
        name: 'Open',
        chapters: {
          const BookChapter('b.pgn', null),
          const BookChapter('a.pgn', 'Najdorf'),
          const BookChapter('a.pgn', 'Dragon'),
          const BookChapter('a.pgn', null),
        },
      );
      expect(book.toJson()['chapters'], [
        {'path': 'a.pgn', 'section': null},
        {'path': 'a.pgn', 'section': 'Dragon'},
        {'path': 'a.pgn', 'section': 'Najdorf'},
        {'path': 'b.pgn', 'section': null},
      ]);
    });
  });

  group('a book chapter read back', () {
    test('keeps a good path, with or without a chapter name', () {
      expect(
        BookChapter.fromJson(const {'path': 'KID/Main.pgn', 'section': null}),
        const BookChapter('KID/Main.pgn', null),
      );
      expect(
        BookChapter.fromJson(const {
          'path': 'Course.pgn',
          'section': 'Najdorf',
        }),
        const BookChapter('Course.pgn', 'Najdorf'),
      );
    });

    test('drops a path that is not a selector, or a name that is not text', () {
      expect(BookChapter.fromJson(const {'path': '/abs.pgn'}), isNull);
      expect(BookChapter.fromJson(const {'path': 'a/../b.pgn'}), isNull);
      expect(BookChapter.fromJson(const {'path': 7}), isNull);
      expect(
        BookChapter.fromJson(const {'path': 'Course.pgn', 'section': 3}),
        isNull,
      );
    });

    test('is the same chapter only with the same path and name', () {
      const chapter = BookChapter('Course.pgn', 'Najdorf');
      expect(chapter, const BookChapter('Course.pgn', 'Najdorf'));
      expect(chapter == const BookChapter('Other.pgn', 'Najdorf'), isFalse);
      expect(chapter == const BookChapter('Course.pgn', 'Dragon'), isFalse);
      expect(chapter == const BookChapter('Course.pgn', null), isFalse);
    });
  });

  group('a list of books decoded', () {
    test('refuses what is not one, so it is never taken for empty', () {
      for (final text in [
        '[]',
        '{"version": 1}',
        '{"version": 1, "books": {}}',
        '{"version": 2, "books": []}',
      ]) {
        expect(
          () => BookList.decode(text),
          throwsFormatException,
          reason: text,
        );
      }
    });

    test('reads a list written before versions, and one of version 1', () {
      expect(BookList.decode('{"books": []}').books, isEmpty);
      final list = BookList.decode(
        const BookList(
          active: 'a',
          books: [
            Book(id: 'a', name: 'Open', repertoires: {'KID'}),
          ],
        ).encode(),
      );
      expect(list.activeBook?.name, 'Open');
    });
  });
}

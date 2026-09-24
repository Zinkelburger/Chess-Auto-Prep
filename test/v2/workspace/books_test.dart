import 'package:chess_auto_prep/v2/storage/book_file.dart';
import 'package:chess_auto_prep/v2/storage/book_list.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/workspace/books.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_files.dart';

/// A store whose file is there and cannot be read.
final class _Unreadable implements BookStore {
  var writes = 0;

  @override
  Future<BookList> read() async => throw const FormatException('torn');

  @override
  Future<void> write(BookList books) async => writes++;
}

void main() {
  late MemoryBooks store;
  late Books books;
  final najdorf = folder('Najdorf', ['Main', 'English Attack', 'Sidelines']);
  final e4 = folder('e4', ['Italian']);

  setUp(() async {
    store = MemoryBooks();
    books = Books(store: store, root: '/repertoires');
    await books.load();
  });
  tearDown(() => books.dispose());

  test('no book is in use until one is made; the first one made is', () async {
    expect(books.active, isNull);
    expect(books.includes(najdorf.chapters.first), isFalse);
    final spring = books.create('Spring Equinox Open')!;
    expect(books.active?.id, spring.id);
    expect(books.editing?.id, spring.id);
    final later = books.create('Later')!;
    expect(books.active?.id, spring.id, reason: 'the one in use stays');
    expect(books.editing?.id, later.id);
    await books.settled;
    expect(store.books.books.map((b) => b.name), [
      'Spring Equinox Open',
      'Later',
    ]);
    expect(store.books.active, spring.id);
  });

  test('a whole repertoire counts, chapters added to it later included, '
      'and a chapter counts on its own', () {
    final book = books.create('Spring')!;
    books.setRepertoire(book, najdorf, true);
    expect(books.shareOf(books.active!, najdorf), BookShare.all);
    expect(books.includes(ref('Najdorf', 'Brand new')), isTrue);
    expect(books.includes(ref('e4', 'Italian')), isFalse);
    books.setChapter(books.active!, e4, ref('e4', 'Italian'), true);
    expect(books.includes(ref('e4', 'Italian')), isTrue);
    expect(books.shareOf(books.active!, e4), BookShare.all);
  });

  test('taking one chapter out of a whole repertoire keeps the others', () {
    final book = books.create('Spring')!;
    books.setRepertoire(book, najdorf, true);
    books.setChapter(
      books.active!,
      najdorf,
      ref('Najdorf', 'Sidelines'),
      false,
    );
    final active = books.active!;
    expect(active.repertoires, isEmpty);
    expect(books.shareOf(active, najdorf), BookShare.some);
    expect(books.includes(ref('Najdorf', 'Main')), isTrue);
    expect(books.includes(ref('Najdorf', 'English Attack')), isTrue);
    expect(books.includes(ref('Najdorf', 'Sidelines')), isFalse);
  });

  test(
    'removing a repertoire clears nested selections but preserves siblings',
    () async {
      final nested = ref('Najdorf/English Attack', 'Main');
      final sibling = ref('Najdorf extra', 'Main');
      final recursive = RepertoireFolder(
        name: 'Najdorf',
        path: '/repertoires/Najdorf',
        modified: DateTime(2026),
        chapters: [...najdorf.chapters, nested],
      );
      books.create('Spring');
      books.setChapter(books.active!, recursive, nested, true);
      books.setChapter(books.active!, recursive, sibling, true);
      books.setRepertoire(
        books.active!,
        folder('Najdorf/Other', ['Main']),
        true,
      );
      books.setRepertoire(books.active!, recursive, false);
      expect(books.includes(nested), isFalse);
      expect(books.includes(ref('Najdorf/Other', 'Main')), isFalse);
      expect(books.includes(sibling), isTrue);
      expect(books.shareOf(books.active!, recursive), BookShare.none);
      await books.settled;
      final reopened = Books(store: store, root: '/repertoires');
      addTearDown(reopened.dispose);
      await reopened.load();
      expect(reopened.includes(nested), isFalse);
      expect(reopened.includes(sibling), isTrue);
    },
  );

  test('a chapter of a course file counts by its name, and the whole file '
      'counts every chapter in it', () {
    const path = '/repertoires/Course/Course.pgn';
    final scotch = ChapterRef.at(path, section: 'Scotch');
    final ruy = ChapterRef.at(path, section: 'Ruy');
    final course = RepertoireFolder(
      name: 'Course',
      path: '/repertoires/Course',
      modified: DateTime(2026),
      chapters: [scotch, ruy],
    );
    final book = books.create('Spring')!;
    books.setChapter(book, course, scotch, true);
    expect(books.includes(scotch), isTrue);
    expect(books.includes(ruy), isFalse);
    expect(books.shareOf(books.active!, course), BookShare.some);
  });

  test('renames and moves in the library are followed', () {
    final book = books.create('Spring')!;
    books
      ..setRepertoire(book, najdorf, true)
      ..setChapter(books.active!, e4, ref('e4', 'Italian'), true)
      ..movedFolder('/repertoires/Najdorf', '/repertoires/Sicilian')
      ..movedFile('/repertoires/e4/Italian.pgn', '/repertoires/e4/Giuoco.pgn');
    expect(books.includes(ref('Sicilian', 'Main')), isTrue);
    expect(books.includes(ref('Najdorf', 'Main')), isFalse);
    expect(books.includes(ref('e4', 'Giuoco')), isTrue);
    expect(books.includes(ref('e4', 'Italian')), isFalse);
  });

  test('deleting the book in use leaves none in use', () {
    final book = books.create('Spring')!;
    books.delete(book);
    expect(books.active, isNull);
    expect(books.books, isEmpty);
  });

  test('a file that cannot be read is never written over', () async {
    final unreadable = _Unreadable();
    final torn = Books(store: unreadable, root: '/repertoires');
    addTearDown(torn.dispose);
    await torn.load();
    expect(torn.problem, isNotNull);
    expect(torn.create('Spring'), isNull);
    await torn.settled;
    expect(unreadable.writes, 0);
  });

  test('the file reads back what was written', () {
    final list = BookList(
      books: [
        Book(
          id: 'a',
          name: 'Spring',
          repertoires: {'Najdorf'},
          chapters: {const BookChapter('Course/Course.pgn', 'Scotch')},
        ),
      ],
      active: 'a',
    );
    final back = BookList.decode(list.encode());
    expect(back.active, 'a');
    expect(back.activeBook?.repertoires, {'Najdorf'});
    expect(back.activeBook?.chapters, {
      const BookChapter('Course/Course.pgn', 'Scotch'),
    });
    expect(() => BookList.decode('{}'), throwsFormatException);
  });
}

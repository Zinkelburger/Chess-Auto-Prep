import 'dart:async';

import 'package:chess_auto_prep/v2/storage/book_file.dart';
import 'package:chess_auto_prep/v2/storage/book_snapshot.dart';
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
  Future<BookSnapshot> snapshot() async => BookSnapshot(value: await read());

  @override
  Future<BookSnapshot> write(BookList books) async {
    writes++;
    return BookSnapshot(value: books);
  }
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

  test(
    'listeners hear successful persistence after its obligation commits',
    () async {
      final held = _HeldBooks();
      final owner = Books(store: held, root: '/repertoires');
      addTearDown(owner.dispose);
      await owner.load();
      final gate = held.writeGate = Completer<void>();
      final acknowledgements = <bool>[];
      owner.addListener(() => acknowledgements.add(!owner.canRetry));
      owner.create('Pending');
      gate.complete();
      await owner.settled;
      await pumpEventQueue();
      expect(acknowledgements.length, greaterThanOrEqualTo(2));
      expect(acknowledgements.last, isTrue);
    },
  );

  test(
    'membership remains noncurrent until the entire coalesced save acknowledges',
    () async {
      final held = _HeldBooks();
      final owner = Books(store: held, root: '/repertoires');
      addTearDown(owner.dispose);
      await owner.load();
      final states = <bool>[];
      owner.addListener(() => states.add(owner.current));
      final before = owner.revision;
      final first = held.writeGate = Completer<void>();
      owner.create('First');
      expect(owner.revision, greaterThan(before));
      expect(owner.current, isFalse);
      final second = held.writeGate = Completer<void>();
      owner.create('Second');
      first.complete();
      await pumpEventQueue();
      expect(held.writes, 2);
      expect(owner.current, isFalse);
      expect(states, everyElement(isFalse));
      second.complete();
      await owner.settled;
      expect(owner.current, isTrue);
      expect(states.last, isTrue);
      expect(owner.canRetry, isFalse);
      expect(held.value.books.map((book) => book.name), ['First', 'Second']);
    },
  );

  test(
    'failed membership remains noncurrent and retry publishes readiness',
    () async {
      final held = _HeldBooks()..fail = true;
      final owner = Books(store: held, root: '/repertoires');
      addTearDown(owner.dispose);
      await owner.load();
      owner.create('Unconfirmed');
      await owner.settled;
      expect(owner.active?.name, 'Unconfirmed');
      expect(owner.current, isFalse);
      expect(owner.problem, isNotNull);
      held.fail = false;
      var ready = false;
      owner.addListener(() => ready |= owner.current);
      await owner.retry();
      expect(owner.current, isTrue);
      expect(owner.problem, isNull);
      expect(ready, isTrue);
    },
  );

  test(
    'refresh admission and failure retain the prior membership as noncurrent',
    () async {
      final held = _HeldBooks();
      final owner = Books(store: held, root: '/repertoires');
      addTearDown(owner.dispose);
      expect(owner.current, isFalse);
      await owner.load();
      owner.create('Retained');
      await owner.settled;
      final active = owner.active;
      final before = owner.revision;
      final gate = held.readGate = Completer<void>();
      final refresh = owner.load();
      expect(owner.revision, greaterThan(before));
      expect(owner.current, isFalse);
      expect(owner.active, same(active));
      held.failRead = true;
      gate.complete();
      await refresh;
      expect(owner.active, same(active));
      expect(owner.current, isFalse);
      expect(owner.problem, contains('retained'));
      held.failRead = false;
      await owner.load();
      expect(owner.current, isTrue);
    },
  );

  test(
    'an accepted edit retires a held refresh instead of waiting for it',
    () async {
      final held = _HeldBooks();
      final owner = Books(store: held, root: '/repertoires');
      addTearDown(owner.dispose);
      await owner.load();
      final gate = held.readGate = Completer<void>();
      final oldRead = owner.load();
      owner.create('Newer');
      await owner.settled;
      expect(owner.current, isTrue);
      gate.complete();
      await oldRead;
      expect(owner.active?.name, 'Newer');
      expect(owner.current, isTrue);
    },
  );

  test(
    'structural reference publication is not current before reread completes',
    () async {
      final held = _HeldBooks();
      final owner = Books(store: held, root: '/repertoires');
      addTearDown(owner.dispose);
      await owner.load();
      final entered = Completer<void>();
      final release = Completer<void>();
      final changing = owner.changeReferences(() async {
        entered.complete();
        await release.future;
        return true;
      }, failed: (_) => false);
      expect(owner.current, isFalse);
      await entered.future;
      final read = held.readGate = Completer<void>();
      release.complete();
      await pumpEventQueue();
      expect(owner.current, isFalse);
      read.complete();
      expect(await changing, isTrue);
      expect(owner.current, isTrue);
    },
  );

  test('published membership cannot mutate behind its revision', () async {
    final names = <String>{'First'};
    final list = <Book>[Book(id: 'one', name: 'One', repertoires: names)];
    final held = _HeldBooks()..value = BookList(books: list, active: 'one');
    final owner = Books(store: held, root: '/repertoires');
    addTearDown(owner.dispose);
    await owner.load();
    names.add('Unobserved');
    list.clear();
    expect(owner.active!.repertoires, {'First'});
    expect(() => owner.books.clear(), throwsUnsupportedError);
    expect(() => owner.active!.repertoires.clear(), throwsUnsupportedError);
    owner.setRepertoire(owner.active!, najdorf, true);
    expect(() => owner.active!.repertoires.clear(), throwsUnsupportedError);
    await owner.settled;
  });

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

final class _HeldBooks implements BookStore {
  BookList value = BookList.empty;
  Completer<void>? writeGate;
  Completer<void>? readGate;
  bool fail = false;
  bool failRead = false;
  int writes = 0;

  @override
  Future<BookList> read() async {
    await readGate?.future;
    if (failRead) throw StateError('read unavailable');
    return value;
  }

  @override
  Future<BookSnapshot> snapshot() async => BookSnapshot(value: await read());

  @override
  Future<BookSnapshot> write(BookList books) async {
    writes++;
    await writeGate?.future;
    if (fail) throw StateError('write unavailable');
    value = books;
    return BookSnapshot(value: books);
  }
}

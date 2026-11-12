import 'dart:async';

import 'package:chess_auto_prep/storage/book_file.dart';
import 'package:chess_auto_prep/storage/book_list.dart';
import 'package:chess_auto_prep/storage/book_snapshot.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/workspace/book/books.dart';
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
      expect(owner.chosen?.name, 'Unconfirmed');
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
    'past the rebase bound the edit stays owed and load replays it',
    () async {
      final racing = _Racing(
        const BookList(
          books: [Book(id: 'a', name: 'Mine')],
          active: 'a',
        ),
      );
      final owner = Books(store: racing, root: '/repertoires');
      addTearDown(owner.dispose);
      await owner.load();
      racing.rivals = 3;
      owner.rename(owner.chosen!, 'Renamed');
      await owner.settled;
      expect(racing.writes, 3);
      expect(owner.canRetry, isTrue);
      expect(owner.problem, isNotNull);
      expect(owner.chosen?.name, 'Renamed');
      await owner.load();
      expect(owner.canRetry, isFalse);
      expect(owner.current, isTrue);
      const names = ['Renamed', 'Rival 1', 'Rival 2', 'Rival 3'];
      expect(racing.value.books.map((book) => book.name), names);
      expect(owner.books.map((book) => book.name), names);
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
      expect(owner.chosen?.name, 'Newer');
      expect(owner.current, isTrue);
    },
  );

  test(
    'a refresh that fails after a newer edit leaves the books writable',
    () async {
      final held = _HeldBooks();
      final owner = Books(store: held, root: '/repertoires');
      addTearDown(owner.dispose);
      await owner.load();
      final gate = held.readGate = Completer<void>();
      final oldRead = owner.load();
      owner.create('Newer');
      await owner.settled;
      held.failRead = true;
      gate.complete();
      await oldRead;
      expect(owner.problem, isNull);
      expect(owner.current, isTrue);
      expect(owner.create('Later'), isNotNull);
      await owner.settled;
      expect(held.value.books.map((book) => book.name), ['Newer', 'Later']);
    },
  );

  test('an edit the file took is not made again when the books are read '
      'after a reference change', () async {
    final held = _HeldBooks()
      ..value = const BookList(
        books: [Book(id: 'a', name: 'Mine')],
        active: 'a',
      );
    final owner = Books(store: held, root: '/repertoires');
    addTearDown(owner.dispose);
    await owner.load();
    owner.rename(owner.chosen!, 'Renamed');
    await owner.settled;
    expect(held.value.activeBook?.name, 'Renamed');
    held.value = const BookList(
      books: [Book(id: 'a', name: 'Theirs')],
      active: 'a',
    );
    await owner.changeReferences(() async => true, failed: (_) => false);
    expect(owner.chosen?.name, 'Theirs');
    expect(held.value.activeBook?.name, 'Theirs');
  });

  test('an edit the file has not taken is kept over a reference change and '
      'written once the file takes writes again', () async {
    final held = _HeldBooks()..fail = true;
    final owner = Books(store: held, root: '/repertoires');
    addTearDown(owner.dispose);
    await owner.load();
    owner.create('Pending');
    await owner.settled;
    expect(owner.canRetry, isTrue);
    await owner.changeReferences(() async {
      held.value = const BookList(
        books: [Book(id: 'x', name: 'Moved')],
      );
      return true;
    }, failed: (_) => false);
    expect(owner.books.map((book) => book.name), ['Moved', 'Pending']);
    held.fail = false;
    await owner.retry();
    expect(held.value.books.map((book) => book.name), ['Moved', 'Pending']);
  });

  test('an edit made as a failed save comes through is written too', () async {
    final held = _HeldBooks()..fail = true;
    final owner = Books(store: held, root: '/repertoires');
    addTearDown(owner.dispose);
    await owner.load();
    owner.create('First');
    await owner.settled;
    expect(owner.problem, isNotNull);
    held.fail = false;
    var made = false;
    owner.addListener(() {
      if (owner.problem == null && !made) {
        made = true;
        owner.create('Second');
      }
    });
    await owner.retry();
    await owner.settled;
    expect(made, isTrue);
    expect(held.value.books.map((book) => book.name), ['First', 'Second']);
    expect(owner.current, isTrue);
  });

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
    expect(owner.chosen!.repertoires, {'First'});
    expect(() => owner.books.clear(), throwsUnsupportedError);
    expect(() => owner.chosen!.repertoires.clear(), throwsUnsupportedError);
    owner.setRepertoire(owner.chosen!, najdorf, true);
    expect(() => owner.chosen!.repertoires.clear(), throwsUnsupportedError);
    await owner.settled;
  });

  test('every repertoire is the book until one is made; the first one made '
      'is in use', () async {
    expect(books.chosen, isNull);
    expect(books.active.name, 'All repertoires');
    expect(books.includes(najdorf.chapters.first), isTrue);
    expect(books.inputs(books.active), {'/repertoires'});
    final spring = books.create('Spring Equinox Open')!;
    expect(books.chosen?.id, spring.id);
    expect(books.editing?.id, spring.id);
    final later = books.create('Later')!;
    expect(books.chosen?.id, spring.id, reason: 'the one in use stays');
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
    expect(books.shareOf(books.chosen!, najdorf), BookShare.all);
    expect(books.includes(ref('Najdorf', 'Brand new')), isTrue);
    expect(books.includes(ref('e4', 'Italian')), isFalse);
    books.setChapter(books.chosen!, e4, ref('e4', 'Italian'), true);
    expect(books.includes(ref('e4', 'Italian')), isTrue);
    expect(books.shareOf(books.chosen!, e4), BookShare.all);
  });

  test('taking one chapter out of a whole repertoire keeps the others', () {
    final book = books.create('Spring')!;
    books.setRepertoire(book, najdorf, true);
    books.setChapter(
      books.chosen!,
      najdorf,
      ref('Najdorf', 'Sidelines'),
      false,
    );
    final active = books.chosen!;
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
      books.setChapter(books.chosen!, recursive, nested, true);
      books.setChapter(books.chosen!, recursive, sibling, true);
      books.setRepertoire(
        books.chosen!,
        folder('Najdorf/Other', ['Main']),
        true,
      );
      books.setRepertoire(books.chosen!, recursive, false);
      expect(books.includes(nested), isFalse);
      expect(books.includes(ref('Najdorf/Other', 'Main')), isFalse);
      expect(books.includes(sibling), isTrue);
      expect(books.shareOf(books.chosen!, recursive), BookShare.none);
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
    expect(books.shareOf(books.chosen!, course), BookShare.some);
  });

  test('deleting the book in use leaves none in use', () {
    final book = books.create('Spring')!;
    books.delete(book);
    expect(books.chosen, isNull);
    expect(books.books, isEmpty);
  });

  test('a name is taken by another book whatever its case and spaces', () {
    final spring = books.create('Spring')!;
    books.create('Summer');
    expect(books.nameTaken(' spring '), isTrue);
    expect(books.nameTaken('SUMMER'), isTrue);
    expect(books.nameTaken('Autumn'), isFalse);
    expect(books.nameTaken('Spring', except: spring), isFalse);
  });

  test('the book chosen is the one used; choosing none uses every '
      'repertoire', () async {
    final spring = books.create('Spring')!;
    final summer = books.create('Summer')!;
    expect(books.chosen?.id, spring.id);
    books.activate(summer);
    expect(books.chosen?.id, summer.id);
    await books.settled;
    expect(store.books.active, summer.id);
    var heard = 0;
    books.addListener(() => heard++);
    books.activate(summer);
    expect(heard, 0, reason: 'the book in use again changes nothing');
    books.activate(null);
    expect(books.chosen, isNull);
    expect(books.active, same(Book.everything));
    await books.settled;
    expect(store.books.active, isNull);
  });

  test('the Books mode opens the book asked for', () {
    final spring = books.create('Spring')!;
    final summer = books.create('Summer')!;
    expect(books.editing?.id, summer.id, reason: 'a new book opens');
    books.edit(spring);
    expect(books.editing?.id, spring.id);
    var heard = 0;
    books.addListener(() => heard++);
    books.edit(spring);
    expect(heard, 0, reason: 'the open book again changes nothing');
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

/// A store that refuses a write over a file changed since it was last read,
/// with another instance adding a book just before each of the next
/// [rivals] writes.
final class _Racing implements BookStore {
  _Racing(this.value) : _baseline = value;

  BookList value;
  BookList _baseline;
  int rivals = 0;
  int writes = 0;
  int _rivalWrites = 0;

  @override
  Future<BookList> read() async => value;

  @override
  Future<BookSnapshot> snapshot() async {
    _baseline = value;
    return BookSnapshot(value: value);
  }

  @override
  Future<BookSnapshot> write(BookList books) async {
    writes++;
    if (rivals > 0) {
      rivals--;
      final n = ++_rivalWrites;
      value = BookList(
        books: [
          ...value.books,
          Book(id: 'r$n', name: 'Rival $n'),
        ],
        active: value.active,
      );
    }
    if (!identical(value, _baseline)) throw const BookConflict();
    value = _baseline = books;
    return BookSnapshot(value: books);
  }
}

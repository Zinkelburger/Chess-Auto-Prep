import 'dart:async';

import 'package:chess_auto_prep/v2/chess/book/book_check.dart';
import 'package:chess_auto_prep/v2/chess/tactics/game_ids.dart';
import 'package:chess_auto_prep/v2/features/my_games/book_words.dart';
import 'package:chess_auto_prep/v2/features/my_games/game_book.dart';
import 'package:chess_auto_prep/v2/storage/book_file.dart';
import 'package:chess_auto_prep/v2/storage/book_snapshot.dart';
import 'package:chess_auto_prep/v2/storage/book_list.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/my_accounts.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/workspace/books.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/book_fixture.dart';
import '../../support/scripted_files.dart';
import '../../support/scripted_store.dart';

void main() {
  late BookFixture fixture;

  setUp(() => fixture = BookFixture());
  tearDown(() => fixture.dispose());

  Future<BookChecked> watched() async {
    fixture.book.watch();
    await pumpEventQueue();
    return fixture.book.state as BookChecked;
  }

  test('reads nothing until a pane is watching', () async {
    fixture.book.recheck();
    await pumpEventQueue();
    expect(fixture.book.state, isA<BookReading>());
    expect(fixture.files.listings, 0);
  });

  test(
    'checks every saved game, newest first, from the user\'s side',
    () async {
      final checked = await watched();
      expect(
        [for (final c in checked.games) verdictLine(c)],
        [
          'Not in your book: 2...Nc6',
          'You left book: 2.Nc3 (book 2.Nf3)',
          'Book ended after 3...cxd4',
          'You left book: 2.Nc3 (book 2.Nf3)',
          'Another opening',
        ],
      );
      final black = checked.games[2];
      expect(black.site, GameSite.lichess);
      expect(black.file, fixture.gamesFile);
      expect(black.game.index, 2);
      expect(black.moment, 6);
    },
  );

  test('groups the games that left the same way, most often first', () async {
    final checked = await watched();
    final mine = checked.waysOf(Deviation.mine);
    expect(mine, hasLength(1));
    expect(
      [for (final g in mine.single.games) g.game.date],
      ['2026.09.20', '2026.09.18'],
    );
    expect(checked.waysOf(Deviation.theirs).single.verdict.played, '2...Nc6');
    expect(checked.waysOf(Deviation.bookEnded).single.games, hasLength(1));
    expect(checked.ways.first, same(mine.single));
  });

  test('finds the game a file holds, and the ones either side of it', () async {
    final checked = await watched();
    final second = checked.games[1];
    expect(fixture.book.find(fixture.gamesFile, second.game.index), second);
    expect(fixture.book.find(fixture.gamesFile, 99), isNull);
    expect(
      fixture.book.step(fixture.gamesFile, second.game.index, 1),
      checked.games[2],
    );
    expect(
      fixture.book.step(fixture.gamesFile, checked.games.first.game.index, -1),
      isNull,
    );
  });

  test('the search narrows the list, and a step walks only the games it '
      'finds', () async {
    final checked = await watched();
    fixture.book.search(' NC3 ');
    expect(fixture.book.query, 'nc3');
    final shown = fixture.book.shown;
    expect([for (final c in shown) c.game.date], ['2026.09.20', '2026.09.18']);
    final file = fixture.gamesFile;
    expect(fixture.book.step(file, shown.first.game.index, 1), shown.last);
    expect(fixture.book.step(file, shown.last.game.index, 1), isNull);
    // From a game the search hides, a step goes to the nearest one it finds
    // that way.
    final hidden = checked.games[2];
    expect(fixture.book.step(file, hidden.game.index, -1), shown.first);
    expect(fixture.book.step(file, hidden.game.index, 1), shown.last);
    fixture.book.search('');
    expect(fixture.book.shown, checked.games);
  });

  test('a course file\'s chapter is read as its own book, and opens as '
      'that chapter', () async {
    const course =
        '// Color: White\n\n'
        '[Event "Sicilian"]\n[ChapterName "Open"]\n[Result "*"]\n\n'
        '1. e4 c5 2. Nf3 d6 3. d4 *\n\n'
        '[Event "Sicilian"]\n[ChapterName "Alapin"]\n[Result "*"]\n\n'
        '1. e4 c5 2. c3 d5 *\n';
    fixture.store.documents[sicilianRef] = Opened(
      course,
      scriptedRevision(course),
    );
    final open = ChapterRef.at(sicilianRef.path, section: 'Open');
    final alapin = ChapterRef.at(sicilianRef.path, section: 'Alapin');
    fixture.files.listing = Repertoires([
      RepertoireFolder(
        name: 'e4',
        path: '/repertoires/e4',
        modified: DateTime(2026),
        chapters: [open, alapin],
      ),
      folder('Najdorf', ['Main']),
    ]);
    final checked = await watched();
    // 2.Nc3 left both chapters, each of them one line through 1...c5.
    final left = checked.games[1].verdict as LeftBook;
    final byMove = {for (final move in left.book) move.label: move};
    expect(byMove.keys, unorderedEquals(['2.Nf3', '2.c3']));
    expect(byMove['2.Nf3']!.lines, 1);
    expect(byMove['2.Nf3']!.file.ref, open);
    expect(byMove['2.c3']!.lines, 1);
    expect(byMove['2.c3']!.file.ref, alapin);
    expect(byMove['2.c3']!.place.file.name, 'Alapin');
  });

  test('reads again when new games are saved while it is watched', () async {
    await watched();
    fixture.saveGames([
      ...savedGames,
      myGame('game0006', '2026.09.22', '1. e4 c5 2. Nf3 d6 3. d4'),
    ]);
    fixture.book.recheck();
    await pumpEventQueue();
    final checked = fixture.book.state as BookChecked;
    expect(checked.games, hasLength(6));
    expect(verdictLine(checked.games.first), 'In book to the end');
  });

  test('a changed repertoire changes the verdicts on the next read', () async {
    await watched();
    const withNc3 =
        '$whiteSicilian\n[Event "Sicilian"]\n[Result "*"]\n\n1. e4 c5 2. Nc3 *\n';
    fixture.store.documents[sicilianRef] = Opened(
      withNc3,
      scriptedRevision(withNc3),
    );
    fixture.book.recheck();
    await pumpEventQueue();
    final checked = fixture.book.state as BookChecked;
    expect(verdictLine(checked.games[1]), 'Book ended after 2.Nc3');
    expect(verdictLine(checked.games[3]), 'In book to the end');
    expect(checked.waysOf(Deviation.mine), isEmpty);
  });

  test('says so when no username is saved', () async {
    await fixture.accounts.setUsername(GameSite.lichess, null);
    fixture.book.watch();
    await pumpEventQueue();
    expect(fixture.book.state, isA<BookNoAccounts>());
  });

  test(
    'failed books reload invalidates the same active book and can recover',
    () async {
      final store = _ReadableBooks();
      final books = Books(store: store, root: '/repertoires');
      addTearDown(books.dispose);
      await books.load();
      final active = books.active;
      final comparison = GameBook(
        accounts: fixture.accounts,
        cache: fixture.cache,
        shelf: fixture.shelf,
        books: books,
      );
      addTearDown(comparison.dispose);
      comparison.watch();
      await pumpEventQueue();
      final previous = comparison.state as BookChecked;
      expect(comparison.stale, isFalse);

      store.unavailable = true;
      await books.load();
      await pumpEventQueue();
      expect(books.active, same(active));
      expect(books.problem, isNotNull);
      expect(comparison.state, same(previous));
      expect(comparison.stale, isTrue);
      expect(comparison.checking, isFalse);
      expect(comparison.problem, contains(books.problem!));
      expect(
        comparison.step(fixture.gamesFile, previous.games.first.game.index, 1),
        isNull,
      );

      store.unavailable = false;
      await books.load();
      await pumpEventQueue();
      expect(books.active?.id, active?.id);
      expect(comparison.stale, isFalse);
      expect(comparison.problem, isNull);
      expect(
        (comparison.state as BookChecked).games,
        hasLength(previous.games.length),
      );
    },
  );

  test(
    'unavailable accounts are an error, never an empty account selection',
    () async {
      SharedPreferences.setMockInitialValues({'lichess_username': 'Me'});
      addTearDown(() => SharedPreferences.setMockInitialValues({}));
      var unavailable = true;
      final accounts = PreferencesAccounts(
        preferences: () async {
          if (unavailable) throw StateError('account preferences unavailable');
          return SharedPreferences.getInstance();
        },
      );
      final comparison = GameBook(
        accounts: accounts,
        cache: fixture.cache,
        shelf: fixture.shelf,
        books: fixture.books,
      );
      addTearDown(comparison.dispose);
      comparison.watch();
      await pumpEventQueue();
      expect(comparison.state, isNot(isA<BookNoAccounts>()));
      expect(comparison.state, isNot(isA<BookChecked>()));
      expect(comparison.stale, isTrue);
      expect(comparison.checking, isFalse);
      expect(comparison.problem, isNotNull);

      unavailable = false;
      comparison.recheck();
      await pumpEventQueue();
      final previous = comparison.state as BookChecked;
      expect(previous.games, hasLength(savedGames.length));
      expect(comparison.stale, isFalse);
      expect(comparison.problem, isNull);

      unavailable = true;
      comparison.recheck();
      await pumpEventQueue();
      expect(comparison.state, same(previous));
      expect(comparison.stale, isTrue);
      expect(comparison.checking, isFalse);
      expect(comparison.problem, isNotNull);
      expect(
        comparison.step(fixture.gamesFile, previous.games.first.game.index, 1),
        isNull,
      );
    },
  );

  test(
    'book membership publication gates comparison and its Retry settles failed writes',
    () async {
      final store = _ReadableBooks();
      final books = Books(store: store, root: '/repertoires');
      addTearDown(books.dispose);
      await books.load();
      final comparison = GameBook(
        accounts: fixture.accounts,
        cache: fixture.cache,
        shelf: fixture.shelf,
        books: books,
      );
      addTearDown(comparison.dispose);
      comparison.watch();
      await pumpEventQueue();
      final previous = comparison.state as BookChecked;

      final held = store.writeGate = Completer<void>();
      books.setRepertoire(books.active!, folder('e4', ['Sicilian']), false);
      await pumpEventQueue();
      expect(comparison.state, same(previous));
      expect(comparison.stale, isTrue);
      expect(
        comparison.step(fixture.gamesFile, previous.games.first.game.index, 1),
        isNull,
      );
      held.complete();
      await books.settled;
      await pumpEventQueue();
      final current = comparison.state as BookChecked;
      expect(current, isNot(same(previous)));
      expect(
        verdictLine(current.games.first),
        'Your book has no White chapters',
      );
      expect(comparison.stale, isFalse);
      expect(comparison.problem, isNull);

      store.failWrite = true;
      books.setRepertoire(books.active!, folder('e4', ['Sicilian']), true);
      await books.settled;
      await pumpEventQueue();
      expect(comparison.state, same(current));
      expect(comparison.stale, isTrue);
      expect(comparison.problem, isNotNull);
      store.failWrite = false;
      await comparison.retry();
      await pumpEventQueue();
      expect(comparison.stale, isFalse);
      expect(comparison.problem, isNull);
      expect(
        verdictLine((comparison.state as BookChecked).games.first),
        verdictLine(previous.games.first),
      );
    },
  );

  test('a read overtaken by a later one is dropped', () async {
    var told = 0;
    fixture.book.addListener(() => told++);
    fixture.files.hold = true;
    fixture.book.watch();
    await pumpEventQueue();
    fixture.saveGames([savedGames.first]);
    fixture.book.recheck();
    await pumpEventQueue();
    fixture.files
      ..hold = false
      ..releaseAll();
    await pumpEventQueue();
    expect(told, 1);
    expect((fixture.book.state as BookChecked).games, hasLength(1));
  });
  test(
    'unreadable downloaded corpus retains the last complete comparison',
    () async {
      final previous = await watched();
      fixture.store.documents[fixture.gamesFile] = const Unreadable(
        'offline corpus',
      );
      fixture.book.recheck();
      await pumpEventQueue();
      expect(fixture.book.state, same(previous));
    },
  );

  test(
    'unreadable book chapter never publishes an incomplete comparison',
    () async {
      final previous = await watched();
      fixture.store.documents[sicilianRef] = const Unreadable(
        'offline chapter',
      );
      fixture.book.recheck();
      await pumpEventQueue();
      expect(fixture.book.state, same(previous));
    },
  );

  test('first unreadable corpus is not an empty successful result', () async {
    fixture.store.documents[fixture.gamesFile] = const Unreadable(
      'offline corpus',
    );
    fixture.book.watch();
    await pumpEventQueue();
    expect(fixture.book.state, isNot(isA<BookChecked>()));
  });

  test(
    'a failed comparison is labelled stale and can retry without losing games',
    () async {
      final previous = await watched();
      final original = fixture.store.documents[fixture.gamesFile]!;
      fixture.store.documents[fixture.gamesFile] = const Unreadable(
        'offline corpus',
      );
      fixture.book.recheck();
      await pumpEventQueue();
      expect(fixture.book.state, same(previous));
      expect(fixture.book.stale, isTrue);
      expect(fixture.book.checking, isFalse);
      expect(fixture.book.problem, contains('offline corpus'));
      expect(
        fixture.book.step(
          fixture.gamesFile,
          previous.games.first.game.index,
          1,
        ),
        isNull,
      );
      fixture.store.documents[fixture.gamesFile] = original;
      fixture.book.recheck();
      await pumpEventQueue();
      expect(fixture.book.stale, isFalse);
      expect(fixture.book.problem, isNull);
      expect(
        (fixture.book.state as BookChecked).games,
        hasLength(previous.games.length),
      );
    },
  );

  test(
    'final fence binds downloaded corpus to the same repertoire snapshot',
    () async {
      final previous = await watched();
      fixture.files.validateWith = (listing, revisions) async {
        if (fixture.files.additionalValidations.last.isNotEmpty) {
          expect(fixture.files.additionalValidations.last.keys, [
            fixture.gamesRef.path,
          ]);
          return const RepertoireChanged();
        }
        return const RepertoireCurrent();
      };
      fixture.saveGames([savedGames.first]);
      fixture.book.recheck();
      await pumpEventQueue();
      expect(fixture.book.state, same(previous));
      expect(fixture.book.problem, contains('changed'));
    },
  );

  test('absent corpus is included as an explicit absence proof', () async {
    fixture.store.documents.remove(fixture.gamesRef);
    final checked = await watched();
    expect(checked.games, isEmpty);
    expect(fixture.files.additionalValidations.last, {
      fixture.gamesRef.path: null,
    });
    expect(fixture.book.stale, isFalse);
  });

  test(
    'username changing during final validation cannot publish prior account games',
    () async {
      final previous = await watched();
      fixture.files.validateWith = (listing, revisions) async {
        if (fixture.files.additionalValidations.last.isNotEmpty) {
          await fixture.accounts.setUsername(GameSite.lichess, 'SomeoneElse');
        }
        return const RepertoireCurrent();
      };
      fixture.book.recheck();
      await pumpEventQueue();
      expect(fixture.book.state, same(previous));
      expect(fixture.book.stale, isTrue);
      expect(fixture.book.problem, contains('inputs changed'));
    },
  );
}

final class _ReadableBooks implements BookStore {
  bool unavailable = false;
  bool failWrite = false;
  Completer<void>? writeGate;
  BookList books = const BookList(
    books: [
      Book(id: 'test', name: 'Test book', repertoires: {'e4', 'Najdorf'}),
    ],
    active: 'test',
  );

  @override
  Future<BookList> read() async {
    if (unavailable) throw StateError('books unavailable');
    return books;
  }

  @override
  Future<BookSnapshot> snapshot() async => BookSnapshot(value: await read());

  @override
  Future<BookSnapshot> write(BookList value) async {
    await writeGate?.future;
    if (failWrite) throw StateError('books write unavailable');
    books = value;
    return BookSnapshot(value: value);
  }
}

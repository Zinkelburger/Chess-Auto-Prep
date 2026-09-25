import 'dart:async';
import 'dart:io';

import 'package:chess_auto_prep/v2/chess/tactics/game_ids.dart';
import 'package:chess_auto_prep/v2/features/my_games/game_book.dart';
import 'package:chess_auto_prep/v2/storage/book_file.dart';
import 'package:chess_auto_prep/v2/storage/book_list.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/my_accounts.dart';
import 'package:chess_auto_prep/v2/storage/my_games_files.dart';
import 'package:chess_auto_prep/v2/workspace/books.dart';
import 'package:chess_auto_prep/v2/workspace/repertoire_shelf.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../storage/store_fixture.dart';
import '../../support/book_fixture.dart' show whiteSicilian, savedGames;
import '../../support/my_games_fixture.dart' show MemoryAccounts;

final selected = BookList(
  active: 'book',
  books: [
    Book(id: 'book', name: 'Book', repertoires: {'Course'}),
  ],
);

void main() {
  late StoreFixture disk;
  late BookFile file;
  late Books books;
  late GameBook comparison;
  late RepertoireShelf shelf;

  Future<void> settles(void Function() action) async {
    final completed = Completer<void>();
    void listener() {
      if (!comparison.checking && !completed.isCompleted) completed.complete();
    }

    comparison.addListener(listener);
    try {
      action();
      await completed.future.timeout(const Duration(seconds: 10));
    } finally {
      comparison.removeListener(listener);
    }
  }

  Future<void> start({bool hasBook = true, bool hasAccount = true}) async {
    disk = await StoreFixture.create();
    final root = Directory(p.join(disk.documents.path, 'repertoires'));
    await disk.put(disk.ref('repertoires/Course/Main.pgn'), whiteSicilian);
    file = BookFile(disk.support, recovery: disk.store.recovery);
    await file.snapshot();
    if (hasBook) await file.write(selected);
    books = Books(root: root.path, store: file);
    await books.load();
    final cache = GamesCache(
      disk.store,
      folder: p.join(disk.documents.path, 'games_library'),
    );
    await disk.put(
      cache.refFor(GameSite.lichess, 'Me'),
      savedGames.join('\n\n'),
    );
    shelf = RepertoireShelf(
      files: ChapterDirectory(root, recovery: disk.store.recovery),
      documents: disk.store,
    );
    comparison = GameBook(
      accounts: MemoryAccounts({
        if (hasAccount) GameSite.lichess: const Account('Me'),
      }),
      cache: cache,
      shelf: shelf,
      books: books,
    );
    addTearDown(() async {
      comparison.dispose();
      shelf.dispose();
      books.dispose();
      await disk.dispose();
    });
    await settles(comparison.watch);
  }

  test(
    'native selection change retains comparison until Retry refreshes books',
    () async {
      await start();
      final previous = comparison.state;
      expect(previous, isA<BookChecked>());
      await file.write(BookList.empty);
      await settles(comparison.recheck);
      expect(comparison.state, same(previous));
      expect(comparison.stale, isTrue);
      expect(comparison.problem, isNotNull);
      await comparison.retry();
      if (comparison.checking) await settles(() {});
      expect(comparison.state, isA<BookNotSet>());
      expect(comparison.stale, isFalse);
    },
  );

  test(
    'absent book selection cannot certify no-book after a native creation',
    () async {
      await start(hasBook: false);
      expect(comparison.state, isA<BookNotSet>());
      await file.write(selected);
      await settles(comparison.recheck);
      expect(comparison.stale, isTrue);
      expect(comparison.problem, isNotNull);
      await comparison.retry();
      if (comparison.checking) await settles(() {});
      expect(comparison.state, isA<BookChecked>());
      expect(comparison.stale, isFalse);
    },
  );

  test('no-account result still validates the selected native book', () async {
    await start(hasAccount: false);
    expect(comparison.state, isA<BookNoAccounts>());
    await file.write(BookList.empty);
    await settles(comparison.recheck);
    expect(comparison.stale, isTrue);
    expect(comparison.problem, isNotNull);
  });
}

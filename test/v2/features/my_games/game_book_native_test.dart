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

void main() {
  test(
    'native corpus failure preserves comparison, retry rebuilds from current files',
    () async {
      final disk = await StoreFixture.create();
      addTearDown(disk.dispose);
      final root = Directory(p.join(disk.documents.path, 'repertoires'));
      await disk.put(disk.ref('repertoires/Course/Main.pgn'), whiteSicilian);
      final books = Books(
        root: root.path,
        store: MemoryBooks(
          BookList(
            active: 'book',
            books: [
              Book(id: 'book', name: 'Book', repertoires: {'Course'}),
            ],
          ),
        ),
      );
      addTearDown(books.dispose);
      await books.load();
      final cache = GamesCache(
        disk.store,
        folder: p.join(disk.documents.path, 'games_library'),
      );
      final corpus = cache.refFor(GameSite.lichess, 'Me');
      await disk.put(corpus, '${savedGames.join('\n\n')}\n');
      final shelf = RepertoireShelf(
        files: ChapterDirectory(root, recovery: disk.store.recovery),
        documents: disk.store,
      );
      final book = GameBook(
        accounts: MemoryAccounts({GameSite.lichess: const Account('Me')}),
        cache: cache,
        shelf: shelf,
        books: books,
      );
      addTearDown(book.dispose);
      Future<void> read({bool first = false}) async {
        final completed = Completer<void>();
        void listener() {
          if (!book.checking && !completed.isCompleted) completed.complete();
        }

        book.addListener(listener);
        try {
          first ? book.watch() : book.recheck();
          await completed.future.timeout(const Duration(seconds: 10));
        } finally {
          book.removeListener(listener);
        }
      }

      await read(first: true);
      final previous = book.state as BookChecked;
      expect(previous.games, hasLength(5));
      expect(book.stale, isFalse);
      final kept = '${corpus.path}.kept';
      await File(corpus.path).rename(kept);
      await Link(corpus.path).create(kept);
      await read();
      expect(book.state, same(previous));
      expect(book.problem, isNotNull);
      expect(book.stale, isTrue);
      await Link(corpus.path).delete();
      await File(corpus.path).writeAsString('${savedGames.first}\n');
      await read();
      expect(book.problem, isNull);
      expect(book.stale, isFalse);
      expect((book.state as BookChecked).games, hasLength(1));
    },
  );
}

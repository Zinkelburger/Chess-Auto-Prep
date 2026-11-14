// The training modes' wiring: the My games book compares the games with
// the repertoire again only when something it reads changed (the accounts,
// or a file of the book in use), and a puzzle's other answers are checked
// by a small engine of their own.
import 'package:chess_auto_prep/chess/tactics/game_ids.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/storage/my_accounts.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_files.dart';
import '../support/scripted_store.dart';
import '../support/window_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the My games book', () {
    const najdorfText =
        '// Color: Black\n\n[Event "Najdorf"]\n[Result "*"]\n\n1. e4 c5 *\n';
    final najdorf = ref('Club', 'Najdorf');
    late WindowFixture w;
    late int treeChanges;

    /// The book watched, with an account to compare, and a Club folder
    /// that the book in use ('test': benko and KID) does not hold.
    Future<void> start() async {
      w = WindowFixture();
      addTearDown(w.dispose);
      w.accounts.accounts[GameSite.lichess] = const Account('Me');
      w.store.documents[najdorf] = Opened(
        najdorfText,
        scriptedRevision(najdorfText),
      );
      w.chapterFiles.listing = Repertoires([
        folder('benko', ['Main']),
        folder('KID', ['Main']),
        folder('Club', ['Najdorf']),
      ]);
      await w.parts.books.load();
      await w.library.refresh();
      final book = w.parts.training.book..watch();
      addTearDown(book.unwatch);
      await w.parts.training.myGames.load();
      await pumpEventQueue();
      treeChanges = 0;
      w.parts.workspace.myGamesTree.addListener(() => treeChanges++);
    }

    /// How many times the book has read the accounts since [start].
    int reads() => w.accounts.snapshots;

    test('reads again, and drops the games tree, when the accounts are '
        'read anew', () async {
      await start();
      final before = reads();
      await w.parts.training.myGames.load();
      await pumpEventQueue();
      expect(reads(), before + 2, reason: 'the load, then the book');
      expect(treeChanges, greaterThan(0));
    });

    test('does nothing when My games changes something else', () async {
      await start();
      final before = reads();
      final myGames = w.parts.training.myGames;
      myGames.setSpeeds(w.settings.value.myGameSpeeds);
      await pumpEventQueue();
      expect(reads(), before);
      expect(treeChanges, 0);
    });

    test('reads again for a file of the book in use, not for another '
        "book's", () async {
      await start();
      final before = reads();
      await w.session.open(najdorf);
      w.session.cursor.toEnd();
      w.session.playMove('g1f3');
      await w.saver.flush();
      await w.parts.catalog.synchronize();
      await pumpEventQueue();
      expect(reads(), before, reason: 'Club is not in the book');
      await w.session.open(kidMain);
      w.session.cursor.toEnd();
      w.session.playMove('f3d4');
      await w.saver.flush();
      await w.parts.catalog.synchronize();
      await pumpEventQueue();
      expect(reads(), greaterThan(before));
    });
  });

  test("a puzzle's other answers are checked on one thread and a small "
      'table', () async {
    final asked = <(int, int)>[];
    final w = WindowFixture(
      launchEngine: ({required cores, required memoryMb}) async {
        asked.add((cores, memoryMb));
        return const StartFailed('no engine in this test');
      },
    );
    addTearDown(w.dispose);
    await w.parts.training.puzzles.alternativeEngine!();
    expect(asked, [(1, 64)]);
  });
}

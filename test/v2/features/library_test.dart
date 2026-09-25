import 'dart:async';

import 'package:chess_auto_prep/v2/features/library/library_state.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/storage/training_records.dart' as training;
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

import '../support/library_fixture.dart';
import '../support/scripted_files.dart';
import '../support/scripted_store.dart';

void main() {
  final kid = folder('KID', ['Classical', 'Main']);
  final benko = folder('benko', ['Main']);
  late LibraryFixture fixture;

  Future<void> start([List<RepertoireFolder> folders = const []]) async {
    fixture = await openLibrary(folders);
  }

  tearDown(() => fixture.dispose());

  test('refresh lists the repertoires', () async {
    await start([benko, kid]);
    expect(
      (fixture.library.state as LibraryLoaded).repertoires.map((f) => f.name),
      ['benko', 'KID'],
    );
  });

  test(
    'refreshes coalesce and discard the listing invalidated while reading',
    () async {
      await start([kid]);
      final library = fixture.library;
      fixture.files
        ..hold = true
        ..listing = Repertoires([kid]);
      final first = library.refresh();
      final second = library.refresh();
      expect(fixture.files.pendingCalls, 1);
      fixture.files.releaseNext();
      await pumpEventQueue();
      expect(fixture.files.pendingCalls, 1, reason: 'one fresh read follows');
      fixture.files.listing = const Repertoires([]);
      fixture.files.releaseNext();
      await Future.wait([first, second]);
      expect(library.repertoires, isEmpty);
    },
  );

  test('an unreadable folder is a typed failure, not an exception', () async {
    await start();
    fixture.files.listing = const RepertoiresUnreadable('Permission denied');
    await fixture.library.refresh();
    expect(fixture.library.state, isA<LibraryLoaded>());
    expect(fixture.library.stale, isTrue);
    expect(fixture.library.problem, 'Permission denied');
  });

  test('search filters the list by name', () async {
    await start([benko, kid]);
    fixture.library.search('ki');
    expect(fixture.library.visible.map((f) => f.name), ['KID']);
    expect(fixture.library.repertoires, hasLength(2));
    fixture.library.search('');
    expect(fixture.library.visible, hasLength(2));
  });

  test(
    'stale catalog refuses fresh writes while retaining its previous rows',
    () async {
      await start([kid]);
      fixture.files.listing = const RepertoiresUnreadable('Permission denied');
      await fixture.library.refresh();
      expect(fixture.library.repertoires, [kid]);
      final before = Map.of(fixture.store.documents);
      expect(
        await fixture.library.createRepertoire('New'),
        isA<LibraryFailure>(),
      );
      expect(
        await fixture.library.renameChapter(kid.chapters.first, 'Changed'),
        isA<LibraryFailure>(),
      );
      expect(fixture.store.documents, before);
      fixture.files.listing = Repertoires([kid]);
      await fixture.library.refresh();
      expect(
        await fixture.library.createRepertoire('New'),
        isA<LibraryAdded>(),
      );
    },
  );

  test(
    'stale catalog blocks admission before a held refresh completes',
    () async {
      await start([kid]);
      fixture.files.hold = true;
      final refreshing = fixture.library.catalog.refresh();
      final creating = fixture.library.createChapter(kid, 'New');
      try {
        await pumpEventQueue();
        expect(fixture.textAt('/repertoires/KID/New.pgn'), isNull);
      } finally {
        fixture.files.hold = false;
        fixture.files.releaseAll();
        await refreshing;
      }
      expect(await creating, isA<LibraryFailure>());
    },
  );

  test('a new repertoire is a folder with one empty chapter', () async {
    await start([kid]);
    final result = await fixture.library.createRepertoire('Benoni', Side.black);
    expect(result, isA<LibraryAdded>());
    expect((result as LibraryAdded).first.path, '/repertoires/Benoni/Main.pgn');
    final text = fixture.textAt('/repertoires/Benoni/Main.pgn');
    expect(text, startsWith('// Benoni\n// Color: Black\n// Created on '));
    expect(text, endsWith('\n\n'));
  });

  test('what the library writes is dated by its own clock', () async {
    fixture = await openLibrary([kid], now: () => DateTime(2026, 9, 23, 10));
    await fixture.library.createRepertoire('Benoni', Side.black);
    const created = '// Created on 2026-09-23 10:00:00\n';
    expect(fixture.textAt('/repertoires/Benoni/Main.pgn'), contains(created));
    final imported = await fixture.library.importText(
      '[Event "Open"]\n\n1. e4 e5 *\n',
      name: 'Open games',
    );
    expect(
      fixture.textAt((imported as LibraryAdded).first.path),
      contains(created),
    );
  });

  test(
    'a repertoire made with no side leaves the question to its chapter',
    () async {
      await start([kid]);
      await fixture.library.createRepertoire('Benoni');
      final text = fixture.textAt('/repertoires/Benoni/Main.pgn');
      expect(text, startsWith('// Benoni\n// Created on '));
      expect(text, isNot(contains('// Color:')));
    },
  );

  test('a repertoire name already in the list is refused', () async {
    await start([kid]);
    expect(
      await fixture.library.createRepertoire('kid', Side.white),
      isA<LibraryNameTaken>(),
    );
    expect(fixture.textAt('/repertoires/kid/Main.pgn'), isNull);
  });

  test('a new chapter takes the side of its repertoire', () async {
    await start([benko]);
    fixture.store.documents[ref('benko', 'Main')] = Opened(
      '// Main\n// Color: Black\n\n',
      scriptedRevision('// Main\n// Color: Black\n\n'),
    );
    expect(
      await fixture.library.createChapter(benko, 'Volga'),
      isA<LibraryDone>(),
    );
    expect(
      fixture.textAt('/repertoires/benko/Volga.pgn'),
      contains('// Color: Black'),
    );
  });

  test('a chapter made for a position writes its root line', () async {
    await start([benko]);
    expect(
      await fixture.library.createChapter(
        benko,
        'Volga',
        rootMoves: const ['d4', 'Nf6', 'c4', 'c5', 'd5', 'b5'],
      ),
      isA<LibraryDone>(),
    );
    expect(
      fixture.textAt('/repertoires/benko/Volga.pgn'),
      contains('// Root: 1. d4 Nf6 2. c4 c5 3. d5 b5\n'),
    );
  });

  test('a chapter name already on disk is refused', () async {
    await start([kid]);
    expect(
      await fixture.library.createChapter(kid, 'Main'),
      isA<LibraryNameTaken>(),
    );
  });

  test('renaming a chapter moves its file', () async {
    await start([benko]);
    expect(
      await fixture.library.renameChapter(ref('benko', 'Main'), 'Mainline'),
      isA<LibraryDone>(),
    );
    expect(fixture.textAt('/repertoires/benko/Main.pgn'), isNull);
    expect(fixture.textAt('/repertoires/benko/Mainline.pgn'), isNotNull);
  });

  test('a rename is refused when the file changed on disk', () async {
    await start([benko]);
    final chapter = ref('benko', 'Main');
    // Somebody else wrote the chapter after the list was read.
    fixture.store.moves.add(const Conflict(null));
    expect(
      await fixture.library.renameChapter(chapter, 'Mainline'),
      isA<LibraryStale>(),
    );
    expect(fixture.textAt(chapter.path), isNotNull);
  });

  test('moving a chapter into another repertoire', () async {
    await start([benko, kid]);
    expect(
      await fixture.library.moveChapter(ref('KID', 'Classical'), benko),
      isA<LibraryDone>(),
    );
    expect(fixture.textAt('/repertoires/benko/Classical.pgn'), isNotNull);
  });

  test('a move onto a name that is taken replaces nothing', () async {
    await start([benko, kid]);
    expect(
      await fixture.library.moveChapter(ref('KID', 'Main'), benko),
      isA<LibraryNameTaken>(),
    );
    expect(fixture.textAt('/repertoires/KID/Main.pgn'), isNotNull);
  });

  test('deleting a chapter says where the training rows went', () async {
    await start([kid]);
    fixture.store.repoint = const training.Repointed(4);
    final result = await fixture.library.deleteChapter(ref('KID', 'Main'));
    expect(result, isA<LibraryDone>());
    expect((result as LibraryDone).training, isA<training.Repointed>());
    expect(fixture.textAt('/repertoires/KID/Main.pgn'), isNull);
  });

  test('deleting a repertoire deletes every chapter and the folder', () async {
    await start([kid]);
    expect(await fixture.library.deleteRepertoire(kid), isA<LibraryDone>());
    expect(fixture.store.documents, isEmpty);
    expect(fixture.files.removed, ['/repertoires/KID']);
  });

  test('a delete that refuses names the chapter it stopped at', () async {
    await start([kid]);
    fixture.store.deletes
      ..add(const Deleted('/recovered/Classical.pgn'))
      ..add(const IoFailure('Read-only file system'));
    final result = await fixture.library.deleteRepertoire(kid);
    expect(result, isA<LibraryStoppedAt>());
    expect((result as LibraryStoppedAt).chapter, 'Main');
    expect(result.cause, isA<LibraryFailure>());
    // The folder is left where it is: half of it is still in it.
    expect(fixture.files.removed, isEmpty);
  });

  test('renaming a repertoire moves the folder whole', () async {
    await start([kid]);
    expect(
      await fixture.library.renameRepertoire(kid, "King's Indian"),
      isA<LibraryDone>(),
    );
    expect(fixture.textAt("/repertoires/King's Indian/Main.pgn"), isNotNull);
    expect(
      fixture.textAt("/repertoires/King's Indian/Classical.pgn"),
      isNotNull,
    );
    expect(fixture.textAt('/repertoires/KID/Main.pgn'), isNull);
    // Nothing is left behind to take away: the folder itself moved.
    expect(fixture.files.removed, isEmpty);
  });

  test('a repertoire rename onto a name in use replaces nothing', () async {
    await start([benko, kid]);
    expect(
      await fixture.library.renameRepertoire(kid, 'BENKO'),
      isA<LibraryNameTaken>(),
    );
    expect(fixture.textAt('/repertoires/KID/Main.pgn'), isNotNull);
    expect(fixture.textAt('/repertoires/benko/Main.pgn'), isNotNull);
  });

  test('a repertoire can be renamed to another spelling of itself', () async {
    await start([kid]);
    expect(
      await fixture.library.renameRepertoire(kid, 'kid'),
      isA<LibraryDone>(),
    );
    expect(fixture.textAt('/repertoires/kid/Main.pgn'), isNotNull);
  });

  test('the workspace follows a chapter whose repertoire is renamed', () async {
    final open = ref('KID', 'Main');
    fixture = await openLibrary([kid], open: open);
    fixture.session.playMove('e2e4');
    await pumpEventQueue();
    expect(
      await fixture.library.renameRepertoire(kid, "King's Indian"),
      isA<LibraryDone>(),
    );
    expect(fixture.session.source?.path, "/repertoires/King's Indian/Main.pgn");
    // The autosave that follows goes to the file's new home.
    fixture.session.playMove('e7e5');
    await pumpEventQueue();
    expect(
      fixture.textAt("/repertoires/King's Indian/Main.pgn"),
      contains('e5'),
    );
  });

  test('a rename of the open chapter that conflicts says to reload', () async {
    final open = ref('benko', 'Main');
    fixture = await openLibrary([benko], open: open);
    // Somebody else wrote the file while the workspace held it open.
    const elsewhere = '// Main\n// Color: White\n\n1. e4 *\n';
    fixture.store.documents[open] = Opened(
      elsewhere,
      scriptedRevision(elsewhere),
    );
    expect(
      await fixture.library.renameChapter(open, 'Mainline'),
      isA<LibraryConflicted>(),
    );
    // Trying again cannot help; taking the version on disk can.
    expect(
      await fixture.library.renameChapter(open, 'Mainline'),
      isA<LibraryConflicted>(),
    );
    await fixture.library.reloadOpenChapter();
    expect(
      await fixture.library.renameChapter(open, 'Mainline'),
      isA<LibraryDone>(),
    );
    expect(fixture.textAt('/repertoires/benko/Mainline.pgn'), isNotNull);
  });

  test(
    'a change refused by a hold already running is busy, not stale',
    () async {
      final open = ref('benko', 'Main');
      fixture = await openLibrary([benko], open: open);
      final holding = Completer<void>();
      final other = fixture.saver.holdStill((_) => holding.future);
      await pumpEventQueue();
      expect(
        await fixture.library.renameChapter(open, 'Mainline'),
        isA<LibraryBusy>(),
      );
      holding.complete();
      await other;
    },
  );

  test('an edit made during a rename is not lost by opening another', () async {
    final open = ref('KID', 'Main');
    fixture = await openLibrary([kid], open: open);
    fixture.store.hold = true;
    final renamed = fixture.library.renameChapter(open, 'Mainline');
    await pumpEventQueue();
    fixture.session.playMove('d2d4');
    // The user gives up waiting and clicks the other chapter.
    final opening = fixture.session.open(ref('KID', 'Classical'));
    await pumpEventQueue();
    fixture.store.hold = false;
    fixture.store.releaseAll();
    await renamed;
    await pumpEventQueue();
    fixture.store.releaseAll();
    await opening;
    expect(fixture.textAt('/repertoires/KID/Mainline.pgn'), contains('d4'));
    expect(fixture.session.source?.name, 'Classical');
  });

  test('one change at a time', () async {
    await start([kid]);
    fixture.store.hold = true;
    final first = fixture.library.deleteChapter(ref('KID', 'Main'));
    await pumpEventQueue();
    expect(fixture.library.busy, isTrue);
    expect(
      await fixture.library.deleteChapter(ref('KID', 'Classical')),
      isA<LibraryBusy>(),
    );
    fixture.store.hold = false;
    fixture.store.releaseAll();
    await first;
  });

  test('renaming the open chapter is serialised with its autosave', () async {
    final open = ref('benko', 'Main');
    fixture = await openLibrary([benko], open: open);
    fixture.store.hold = true;
    fixture.session.playMove('e2e4'); // asks for a save that cannot land yet
    await pumpEventQueue();
    expect(fixture.store.requestedSaves, hasLength(1));
    final renamed = fixture.library.renameChapter(open, 'Mainline');
    await pumpEventQueue();
    // Held still: the rename waits rather than racing the save's answer.
    expect(fixture.textAt('/repertoires/benko/Mainline.pgn'), isNull);
    fixture.store.hold = false;
    fixture.store.releaseAll();
    expect(await renamed, isA<LibraryDone>());
    expect(fixture.textAt('/repertoires/benko/Main.pgn'), isNull);
    expect(fixture.textAt('/repertoires/benko/Mainline.pgn'), contains('e4'));
    expect(fixture.session.source?.name, 'Mainline');
    // The workspace shows the name the file now has, not the one it had open.
    expect(fixture.session.chapter?.name, 'Mainline');
  });

  test('an edit made during the rename goes to the new file', () async {
    final open = ref('benko', 'Main');
    fixture = await openLibrary([benko], open: open);
    fixture.store.hold = true;
    final renamed = fixture.library.renameChapter(open, 'Mainline');
    await pumpEventQueue();
    fixture.session.playMove('d2d4');
    fixture.store.hold = false;
    fixture.store.releaseAll();
    await renamed;
    await pumpEventQueue();
    expect(fixture.textAt('/repertoires/benko/Mainline.pgn'), contains('d4'));
  });

  test('a flush waits for the rename and the edit behind it', () async {
    final open = ref('benko', 'Main');
    fixture = await openLibrary([benko], open: open);
    fixture.store.hold = true;
    final renamed = fixture.library.renameChapter(open, 'Mainline');
    await pumpEventQueue();
    fixture.session.playMove('d2d4');
    var flushed = false;
    final waiting = fixture.saver.flush().then((_) => flushed = true);
    await pumpEventQueue();
    // Closing the window here must not cut the edit off.
    expect(flushed, isFalse);
    fixture.store.hold = false;
    fixture.store.releaseAll();
    await renamed;
    await waiting;
    expect(fixture.textAt('/repertoires/benko/Mainline.pgn'), contains('d4'));
  });

  test('deleting the open chapter writes its draft first', () async {
    final open = ref('benko', 'Main');
    fixture = await openLibrary([benko], open: open);
    fixture.store.hold = true;
    fixture.session.playMove('e2e4');
    await pumpEventQueue();
    final deleted = fixture.library.deleteChapter(open);
    await pumpEventQueue();
    fixture.store.hold = false;
    fixture.store.releaseAll();
    expect(await deleted, isA<LibraryDone>());
    // The edit went to the file, and the file went to recovery with it in.
    expect(fixture.store.requestedSaves.last.text, contains('e4'));
    expect(fixture.textAt(open.path), isNull);
  });

  test('deleting the open chapter shows the analysis board', () async {
    final open = ref('benko', 'Main');
    fixture = await openLibrary([benko], open: open);
    expect(await fixture.library.deleteChapter(open), isA<LibraryDone>());
    expect(fixture.session.source, isNull);
    expect(fixture.session.isScratch, isTrue);
  });

  test('a refresh finishing after dispose stays quiet', () async {
    await start([kid]);
    fixture.files.hold = true;
    final done = fixture.library.refresh();
    fixture.library.dispose();
    fixture.files.releaseNext();
    await done;
    fixture = await openLibrary([kid]); // so tearDown disposes a live one
  });
}

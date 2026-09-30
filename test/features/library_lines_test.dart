import 'dart:async';

import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/diagnostics/log.dart';
import 'package:chess_auto_prep/features/library/library_state.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/pending_writes.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/workspace/document_saver.dart' as editor;
import 'package:chess_auto_prep/workspace/session_results.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/library_fixture.dart';
import '../support/scripted_files.dart';
import '../support/scripted_store.dart';

void main() {
  final kid = folder('KID', ['Classical', 'Main']);
  late LibraryFixture fixture;

  Future<void> start([
    List<RepertoireFolder> folders = const [],
    PendingWrites? pendingWrites,
  ]) async {
    fixture = await openLibrary(folders, pendingWrites: pendingWrites);
  }

  tearDown(() => fixture.dispose());

  const twoLines = '''
// Main
// Color: White

[Event "Queen's"]
[Result "*"]

1. d4 d5 2. c4 e6 *

[Event "Indian"]
[Result "*"]

1. d4 Nf6 *
''';
  const sidelines = '''
// Sidelines
// Color: White

[Event "Catalan"]
[Result "*"]

1. d4 d5 2. c4 e6 3. g3 *
''';

  Future<void> open([PendingWrites? pendingWrites]) async {
    await start([kid], pendingWrites);
    fixture.store.documents[ref('KID', 'Main')] = Opened(
      twoLines,
      scriptedRevision(twoLines),
    );
    fixture.store.documents[ref('KID', 'Sidelines')] = Opened(
      sidelines,
      scriptedRevision(sidelines),
    );
    await fixture.session.open(ref('KID', 'Main'));
  }

  test('dropped on another chapter, lines become games of it and leave '
      'the open one', () async {
    await open();
    expect(
      await fixture.library.moveLines(games: {1}, to: ref('KID', 'Sidelines')),
      isA<LibraryDone>(),
    );
    await fixture.saver.flush();
    final there = fixture.textAt('/repertoires/KID/Sidelines.pgn')!;
    expect(there, contains('[Event "Catalan"]'));
    expect(there, contains('[LineID '));
    expect(there, endsWith('1. d4 Nf6 *\n'));
    final here = fixture.textAt('/repertoires/KID/Main.pgn')!;
    expect(here, isNot(contains('Indian')));
    expect(here, contains("[Event \"Queen's\"]"));
    expect(fixture.session.chapter!.lines.length, 1);
  });

  test('a line whose headers the old app ends early moves as it is', () async {
    // The bare backslash ends the old app's header block: no id header both
    // apps read can go above it, so the line moves carrying what it had.
    const wild = '''
// Main
// Color: White

[Event "c:\\games"]
[Result "*"]

1. d4 Nf6 *
''';
    await start([kid]);
    fixture.store.documents[ref('KID', 'Main')] = Opened(
      wild,
      scriptedRevision(wild),
    );
    fixture.store.documents[ref('KID', 'Sidelines')] = Opened(
      sidelines,
      scriptedRevision(sidelines),
    );
    await fixture.session.open(ref('KID', 'Main'));
    expect(
      await fixture.library.moveLines(games: {0}, to: ref('KID', 'Sidelines')),
      isA<LibraryDone>(),
    );
    await fixture.saver.flush();
    final there = fixture.textAt('/repertoires/KID/Sidelines.pgn')!;
    expect(there, contains('[Event "Catalan"]'));
    expect(
      there,
      endsWith('[Event "c:\\games"]\n[Result "*"]\n\n1. d4 Nf6 *\n'),
    );
    expect(fixture.textAt('/repertoires/KID/Main.pgn'), isNot(contains('Nf6')));
  });

  test('dropped on a line of another chapter, a line folds into it', () async {
    await open();
    expect(
      await fixture.library.moveLines(
        games: {0},
        to: ref('KID', 'Sidelines'),
        asSidelineOf: 0,
      ),
      isA<LibraryDone>(),
    );
    await fixture.saver.flush();
    final there = fixture.textAt('/repertoires/KID/Sidelines.pgn')!;
    // The Queen's line shares 1. d4 d5 2. c4 e6 with the Catalan and adds
    // nothing after it, so the Catalan game is unchanged and the Queen's
    // line is simply gone from Main.
    expect(there, sidelines);
    expect(
      fixture.textAt('/repertoires/KID/Main.pgn'),
      isNot(contains("Queen's")),
    );
  });

  test('dropped on a line of the same chapter, a line folds into it', () async {
    await open();
    expect(
      await fixture.library.moveLines(
        games: {1},
        to: ref('KID', 'Main'),
        asSidelineOf: 0,
      ),
      isA<LibraryDone>(),
    );
    await fixture.saver.flush();
    final here = fixture.textAt('/repertoires/KID/Main.pgn')!;
    expect(here, contains('1. d4 d5 (1... Nf6) 2. c4 e6 *'));
    expect(here, isNot(contains('[Event "Indian"]')));
  });

  const withPartial = '''
// Main
// Color: White

[Event "Queen's"]
[Result "*"]

1. d4 d5 2. c4 *

[Event "Partial"]
[Result "*"]

1. d4 d5 2. Ke3 Nf6 3. Nf3 {my note} *

[Event "Slav"]
[Result "*"]

1. d4 d5 2. c4 c6 *
''';

  Future<void> openPartial() async {
    await open();
    fixture.store.documents[ref('KID', 'Main')] = Opened(
      withPartial,
      scriptedRevision(withPartial),
    );
    await fixture.session.open(ref('KID', 'Main'));
  }

  test('a line that was not read whole does not fold into another', () async {
    await openPartial();
    expect(
      await fixture.library.moveLines(
        games: {1},
        to: ref('KID', 'Main'),
        asSidelineOf: 0,
      ),
      isA<LibraryFailure>(),
    );
    await fixture.saver.flush();
    final here = fixture.textAt('/repertoires/KID/Main.pgn')!;
    expect(here, contains('2. Ke3 Nf6 3. Nf3 {my note}'));
    expect(here, withPartial);
  });

  test('a whole line folds nowhere when a partial one moves with it', () async {
    await openPartial();
    expect(
      await fixture.library.moveLines(
        games: {2, 1},
        to: ref('KID', 'Main'),
        asSidelineOf: 0,
      ),
      isA<LibraryFailure>(),
    );
    await fixture.saver.flush();
    expect(fixture.textAt('/repertoires/KID/Main.pgn'), withPartial);
  });

  test('a line that was not read whole does not fold into a line of '
      'another chapter', () async {
    await openPartial();
    expect(
      await fixture.library.moveLines(
        games: {1},
        to: ref('KID', 'Sidelines'),
        asSidelineOf: 0,
      ),
      isA<LibraryFailure>(),
    );
    await fixture.saver.flush();
    expect(fixture.textAt('/repertoires/KID/Main.pgn'), withPartial);
    expect(fixture.textAt('/repertoires/KID/Sidelines.pgn'), sidelines);
  });

  const classical = '''
// Classical
// Color: White

[Event "Mar del Plata"]
[Result "*"]

1. d4 Nf6 2. c4 g6 *

[Event "Petrosian"]
[Result "*"]

1. d4 Nf6 2. c4 g6 3. Nc3 Bg7 4. e4 d6 5. Nf3 O-O 6. Be2 e5 7. d5 *
''';

  test('a chapter opened while the lines are written keeps its own', () async {
    await open();
    fixture.store.documents[ref('KID', 'Classical')] = Opened(
      classical,
      scriptedRevision(classical),
    );
    fixture.store.hold = true;
    final moved = fixture.library.moveLines(
      games: {1},
      to: ref('KID', 'Sidelines'),
    );
    await pumpEventQueue();
    // The user clicks another chapter while Sidelines is being read.
    final opening = fixture.session.open(ref('KID', 'Classical'));
    await pumpEventQueue();
    fixture.store.hold = false;
    fixture.store.releaseLast(); // Classical opens first
    await opening;
    fixture.store.releaseAll();

    expect(await moved, isA<LibraryFailure>());
    await fixture.saver.flush();
    expect(fixture.textAt('/repertoires/KID/Classical.pgn'), classical);
    expect(fixture.session.chapter!.lines, hasLength(2));
    // The source changed before publication, so neither file is changed.
    expect(
      fixture.textAt('/repertoires/KID/Sidelines.pgn'),
      isNot(contains('[Event "Indian"]')),
    );
    expect(
      fixture.textAt('/repertoires/KID/Main.pgn'),
      contains('[Event "Indian"]'),
    );
  });

  test('a chapter edited while the lines are written keeps them', () async {
    await open();
    fixture.store.hold = true;
    final moved = fixture.library.moveLines(
      games: {1},
      to: ref('KID', 'Sidelines'),
    );
    await pumpEventQueue();
    fixture.session.playMove('c2c4');
    await pumpEventQueue();
    fixture.store.hold = false;
    fixture.store.releaseAll();

    expect(await moved, isA<LibraryFailure>());
    await fixture.saver.flush();
    final here = fixture.textAt('/repertoires/KID/Main.pgn')!;
    expect(here, contains('[Event "Indian"]'));
    expect(here, contains('1. c4'));
  });

  test('a target that changed on disk takes nothing and the open chapter '
      'keeps its lines', () async {
    await open();
    fixture.store.saves.add(const Conflict(null));
    expect(
      await fixture.library.moveLines(games: {1}, to: ref('KID', 'Sidelines')),
      isA<LibraryStale>(),
    );
    expect(fixture.textAt('/repertoires/KID/Sidelines.pgn'), sidelines);
    expect(fixture.session.chapter!.lines.length, 2);
  });

  test('moved to a new chapter, lines become its games and the chapter '
      'takes the open one\'s side', () async {
    await open();
    expect(
      await fixture.library.moveLinesToNewChapter(
        games: {1},
        into: kid,
        name: 'Indian',
      ),
      isA<LibraryDone>(),
    );
    await fixture.saver.flush();
    final there = fixture.textAt('/repertoires/KID/Indian.pgn')!;
    expect(there, startsWith('// Indian\n'));
    expect(there, contains('// Color: White'));
    expect(there, endsWith('1. d4 Nf6 *\n'));
    expect(
      fixture.textAt('/repertoires/KID/Main.pgn'),
      isNot(contains('Indian"]')),
    );
    expect(fixture.session.chapter!.lines.length, 1);
  });

  test('a chapter edited while the new chapter is made moves nothing and '
      'leaves no empty chapter behind', () async {
    await open();
    fixture.store.hold = true;
    final moved = fixture.library.moveLinesToNewChapter(
      games: {1},
      into: kid,
      name: 'Indian',
    );
    await pumpEventQueue();
    fixture.session.playMove('c2c4');
    await pumpEventQueue();
    fixture.store.hold = false;
    fixture.store.releaseAll();

    expect(await moved, isA<LibraryFailure>());
    await fixture.saver.flush();
    expect(fixture.textAt('/repertoires/KID/Indian.pgn'), isNull);
    expect(
      fixture.store.deleted,
      isEmpty,
      reason: 'a chapter nobody saw leaves no recovery copy',
    );
    final here = fixture.textAt('/repertoires/KID/Main.pgn')!;
    expect(here, contains('[Event "Indian"]'));
    expect(
      fixture.session.chapter!.lines,
      hasLength(3),
      reason: 'both lines stay, beside the one 1.c4 started',
    );
  });

  test('a new chapter whose name is taken moves nothing', () async {
    await open();
    expect(
      await fixture.library.moveLinesToNewChapter(
        games: {1},
        into: kid,
        name: 'Sidelines',
      ),
      isA<LibraryNameTaken>(),
    );
    expect(fixture.textAt('/repertoires/KID/Sidelines.pgn'), sidelines);
    expect(fixture.session.chapter!.lines.length, 2);
  });

  /// Moves the Indian line to a new chapter while the open one is edited,
  /// so the move is refused and the new chapter is taken back.
  Future<LibraryResult> refusedMove() async {
    fixture.store.hold = true;
    final moved = fixture.library.moveLinesToNewChapter(
      games: {1},
      into: kid,
      name: 'Indian',
    );
    await pumpEventQueue();
    fixture.session.playMove('c2c4');
    await pumpEventQueue();
    fixture.store.hold = false;
    fixture.store.releaseAll();
    return moved;
  }

  test('a new chapter the list already shows goes to recovery when the '
      'move is refused', () async {
    await open();
    const indian = DocumentRef('/repertoires/KID/Indian.pgn');
    fixture.files.removeUnusedWith = (_, _) => fail('the list shows it');
    fixture.files.listing = Repertoires([
      folder('KID', ['Classical', 'Main', 'Indian']),
    ]);
    await fixture.library.refresh();

    expect(await refusedMove(), isA<LibraryFailure>());
    expect(fixture.textAt(indian.path), isNull);
    expect(fixture.store.deleted.keys, [indian]);
  });

  test('a new chapter that cannot be taken back is logged and stays', () async {
    await open();
    final lines = <String>[];
    void sink(LogEntry entry) => lines.add(entry.line);
    log.install(sink);
    addTearDown(() => log.remove(sink));
    fixture.files.removeUnusedWith = (_, _) => false;
    fixture.store.deletes.add(const IoFailure('disk gone'));

    expect(await refusedMove(), isA<LibraryFailure>());
    expect(fixture.textAt('/repertoires/KID/Indian.pgn'), isNotNull);
    expect(
      lines.where(
        (l) => l.contains('remove the unused chapter') && l.contains('disk'),
      ),
      isNotEmpty,
    );
  });

  group('a line move whose write was not acknowledged', () {
    late PendingWrites writes;
    setUp(() => writes = PendingWrites());

    Future<void> uncertainMove() async {
      await open(writes);
      fixture.store.saves.add(const IoFailure('lock timeout'));
      expect(
        await fixture.library.moveLines(
          games: {0},
          to: ref('KID', 'Sidelines'),
        ),
        isA<LibraryFailure>(),
      );
      expect(fixture.library.hasPendingLineMove, isTrue);
    }

    Future<LibraryResult> newChapter() =>
        fixture.library.createChapter(kid, 'Openings');

    test('settles when its retry meets a changed file, and the library '
        'takes changes again', () async {
      await uncertainMove();
      await fixture.session.open(ref('KID', 'Sidelines'));
      fixture.store.saves.add(Conflict(scriptedRevision('changed')));

      expect(await fixture.library.retryLineMove(), isA<LibraryStale>());
      expect(fixture.library.hasPendingLineMove, isFalse);
      expect(await writes.settle() ?? '', isNot(contains('Move repertoire')));
      expect(await newChapter(), isA<LibraryDone>());
    });

    test('settles when its retry meets a changed file while the source '
        'stays open, and the source takes edits again', () async {
      await uncertainMove();
      fixture.store.saves.add(Conflict(scriptedRevision('changed')));

      expect(await fixture.library.retryLineMove(), isA<LibraryStale>());
      expect(fixture.library.hasPendingLineMove, isFalse);
      expect(fixture.saver.referencesPending, isFalse);
    });

    test('that fails again stays pending until it is discarded', () async {
      await uncertainMove();
      fixture.store.saves.add(const IoFailure('read-only disk'));

      expect(await fixture.library.retryLineMove(), isA<LibraryFailure>());
      expect(fixture.library.hasPendingLineMove, isTrue);
      expect(await newChapter(), isA<LibraryFailure>());
      expect(await writes.settle(), contains('Move repertoire lines'));

      expect(fixture.saver.referencesPending, isTrue);
      expect(fixture.saver.settled, isFalse);

      expect(await fixture.library.discardLineMove(), isTrue);
      expect(fixture.library.hasPendingLineMove, isFalse);
      expect(fixture.saver.referencesPending, isFalse);
      expect(fixture.saver.settled, isTrue);
      expect(await writes.settle() ?? '', isNot(contains('Move repertoire')));
      expect(await newChapter(), isA<LibraryDone>());
    });

    test('a discarded move releases the open source', () async {
      await uncertainMove();
      fixture.store.saves.add(const IoFailure('read-only disk'));
      expect(await fixture.library.retryLineMove(), isA<LibraryFailure>());

      expect(await fixture.library.discardLineMove(), isTrue);
      await pumpEventQueue();
      expect(fixture.saver.referencesPending, isFalse);
      expect(fixture.saver.settled, isTrue);
      final onDisk = fixture.textAt('/repertoires/KID/Main.pgn')!;
      expect(fixture.session.chapter!.lines, hasLength(2));
      expect(onDisk, twoLines);

      fixture.session.setComment(NodePath.of([0]), 'mine');
      await fixture.saver.flush();
      expect(fixture.session.refusedEdit, isNull);
      expect(fixture.textAt('/repertoires/KID/Main.pgn'), contains('{mine}'));
    });

    test('recorded on retry leaves a source opened again as it is', () async {
      await uncertainMove();
      await fixture.session.open(ref('KID', 'Main'));
      final shown = fixture.session.chapter;
      final opens = fixture.store.opens;
      fixture.store.saves.add(const Unfinished('held open by another program'));

      expect(await fixture.library.retryLineMove(), isA<LibraryFailure>());
      expect(fixture.library.hasPendingLineMove, isFalse);
      expect(fixture.store.opens, opens);
      expect(fixture.session.chapter, same(shown));
      expect(fixture.saver.settled, isTrue);
    });

    test('a line move the store recorded leaves the source editor '
        'settled', () async {
      await open(writes);
      fixture.store.saves.add(const Unfinished('held open by another program'));

      expect(
        await fixture.library.moveLines(
          games: {0},
          to: ref('KID', 'Sidelines'),
        ),
        isA<LibraryUnfinished>(),
      );
      expect(fixture.saver.settled, isTrue);
      expect(fixture.saver.referencesPending, isFalse);
      // The chapter was read again; the scripted store still holds what it
      // held, so the move is not on screen yet.
      expect(fixture.saver.state, isA<editor.Saved>());
      expect(fixture.session.chapter!.lines, hasLength(2));

      // The recovery gate finishes the recorded move on a later access.
      for (final save in fixture.store.requestedSaves) {
        fixture.store.documents[save.ref] = Opened(
          save.text,
          scriptedRevision(save.text),
        );
      }
      expect(await fixture.library.reloadOpenChapter(), isA<DocumentOpened>());
      expect(fixture.session.chapter!.lines, hasLength(1));
      fixture.session.setComment(NodePath.of([0]), 'mine');
      await fixture.saver.flush();
      expect(fixture.session.refusedEdit, isNull);
      expect(fixture.textAt('/repertoires/KID/Main.pgn'), contains('{mine}'));
      final again = await fixture.library.moveLines(
        games: {0},
        to: ref('KID', 'Sidelines'),
      );
      expect(
        again,
        isNot(
          isA<LibraryFailure>().having(
            (f) => f.detail,
            'detail',
            'Keep or discard pending edits first.',
          ),
        ),
      );
      expect(again, isA<LibraryDone>());
    });

    test('that the store recorded settles and is finished for it, with '
        'nothing to ask about at exit', () async {
      await open(writes);
      fixture.store.saves.add(const Unfinished('held open by another program'));

      expect(
        await fixture.library.moveLines(
          games: {0},
          to: ref('KID', 'Sidelines'),
        ),
        isA<LibraryFailure>(),
      );
      expect(fixture.library.hasPendingLineMove, isFalse);
      expect(await writes.settle() ?? '', isNot(contains('Move repertoire')));
      expect(fixture.saver.settled, isTrue);
      expect(fixture.saver.referencesPending, isFalse);

      // The recovery gate finishes the recorded move on a later access.
      for (final save in fixture.store.requestedSaves) {
        fixture.store.documents[save.ref] = Opened(
          save.text,
          scriptedRevision(save.text),
        );
      }
      await fixture.session.open(ref('KID', 'Main'));
      expect(fixture.session.chapter!.lines, hasLength(1));
      expect(
        fixture.textAt('/repertoires/KID/Sidelines.pgn'),
        contains("[Event \"Queen's\"]"),
      );
      expect(await newChapter(), isA<LibraryDone>());
      expect(await writes.settle() ?? '', isNot(contains('Move repertoire')));
    });

    test(
      'that the store recorded keeps the new chapter it writes into',
      () async {
        await open(writes);
        fixture.store.saves.add(
          const Unfinished('held open by another program'),
        );

        expect(
          await fixture.library.moveLinesToNewChapter(
            games: {1},
            into: kid,
            name: 'Indian',
          ),
          isA<LibraryFailure>(),
        );
        expect(fixture.library.hasPendingLineMove, isFalse);
        expect(fixture.textAt('/repertoires/KID/Indian.pgn'), isNotNull);
        expect(fixture.store.deleted, isEmpty);
      },
    );

    test('lands on retry and clears the move', () async {
      await uncertainMove();

      expect(await fixture.library.retryLineMove(), isA<LibraryDone>());
      expect(fixture.library.hasPendingLineMove, isFalse);
      expect(
        fixture.textAt('/repertoires/KID/Sidelines.pgn'),
        contains("[Event \"Queen's\"]"),
      );
      expect(await newChapter(), isA<LibraryDone>());
    });
  });
}

import 'dart:async';

import 'package:chess_auto_prep/v2/features/library/library.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/library_fixture.dart';
import '../support/scripted_files.dart';
import '../support/scripted_store.dart';

void main() {
  final kid = folder('KID', ['Classical', 'Main']);
  late LibraryFixture fixture;

  Future<void> start([List<RepertoireFolder> folders = const []]) async {
    fixture = await openLibrary(folders);
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

  Future<void> open() async {
    await start([kid]);
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
    expect(there, endsWith('[Event "Indian"]\n[Result "*"]\n\n1. d4 Nf6 *\n'));
    final here = fixture.textAt('/repertoires/KID/Main.pgn')!;
    expect(here, isNot(contains('Indian')));
    expect(here, contains("[Event \"Queen's\"]"));
    expect(fixture.session.chapter!.lines.length, 1);
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
    // A duplicate the user can see: the lines are in both chapters.
    expect(
      fixture.textAt('/repertoires/KID/Sidelines.pgn'),
      contains('[Event "Indian"]'),
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
}

import 'package:chess_auto_prep/v2/chess/pgn/chapter_heading.dart';
import 'package:chess_auto_prep/v2/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/workspace/chapter_commands.dart';
import 'package:chess_auto_prep/v2/workspace/engine_analysis.dart';
import 'package:chess_auto_prep/v2/workspace/repertoire_shelf.dart';
import 'package:chess_auto_prep/v2/workspace/repertoire_tree.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_files.dart';
import '../support/scripted_store.dart';
import '../support/session_fixture.dart';

/// The chapter on the board: the Italian, two lines after 3.Bc4.
const italian = '''
// Color: White

[Event "Italian"]
[Result "*"]

1. e4 e5 2. Nf3 Nc6 3. Bc4 Bc5 4. c3 *

[Event "Italian"]
[Result "*"]

1. e4 e5 2. Nf3 Nc6 3. Bc4 Nf6 4. d3 *
''';

/// Another White file of the same repertoire: the Ruy, three lines.
const ruy = '''
// Color: White

[Event "Ruy"]
[Result "*"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 Nf6 5. O-O *

[Event "Ruy"]
[Result "*"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 Nf6 4. O-O *

[Event "Ruy"]
[Result "*"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 f5 4. Nc3 *
''';

/// A repertoire of one file with no chapters, reaching the same position
/// by another move order.
const scotchOrder = '''
// Color: White

[Event "Knights"]
[Result "*"]

1. Nf3 Nc6 2. e4 e5 3. d4 exd4 *
''';

/// A Black file, which a White board leaves out.
const sicilian = '''
// Color: Black

[Event "Najdorf"]
[Result "*"]

1. e4 c5 2. Nf3 d6 *
''';

/// A course file of two chapters by tag: the Scotch, one line, and the
/// Ruy, three.
const course = '''
// Color: White

[Event "Scotch"]
[ChapterName "Scotch"]
[Result "*"]

1. e4 e5 2. Nf3 Nc6 3. d4 exd4 *

[Event "Ruy"]
[ChapterName "Ruy"]
[Result "*"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 Nf6 5. O-O *

[Event "Ruy"]
[ChapterName "Ruy"]
[Result "*"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 Nf6 4. O-O *

[Event "Ruy"]
[ChapterName "Ruy"]
[Result "*"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 f5 4. Nc3 *
''';

void main() {
  late SessionFixture fixture;
  late ScriptedFiles files;
  late RepertoireShelf shelf;
  late RepertoireTree tree;

  setUp(() async {
    fixture = await openSession(italian, name: 'Italian', repertoire: 'e4');
    files = ScriptedFiles(
      listing: Repertoires([
        folder('e4', ['Italian', 'Ruy']),
        folder('Knights', ['Knights']),
        folder('Sicilian', ['Najdorf']),
      ]),
    );
    void put(String repertoire, String name, String text) =>
        fixture.store.documents[chapterRef(repertoire, name)] = Opened(
          text,
          scriptedRevision(text),
        );
    put('e4', 'Ruy', ruy);
    put('Knights', 'Knights', scotchOrder);
    put('Sicilian', 'Najdorf', sicilian);
    shelf = RepertoireShelf(files: files, documents: fixture.store);
    tree = RepertoireTree(session: fixture.session, shelf: shelf)..watch();
    await pumpEventQueue();
  });

  tearDown(() {
    tree.dispose();
    fixture.dispose();
  });

  List<TreeRow> rows() => switch (tree.state) {
    TreeShown(:final rows) => rows,
    final other => fail('expected rows, got $other'),
  };

  void walk(List<String> sans) {
    for (final san in sans) {
      final at = fixture.session.cursor;
      final children =
          fixture.session.tree!.nodeAt(at)?.children ??
          fixture.session.tree!.children;
      fixture.session.goTo(at.child(children.indexWhere((n) => n.san == san)));
    }
  }

  test('lists every file of the side, most lines first', () async {
    walk(['e4', 'e5', 'Nf3', 'Nc6']);
    await pumpEventQueue();
    final shown = rows();
    expect([for (final row in shown) row.san], ['Bb5', 'Bc4', 'd4']);
    expect([for (final row in shown) row.lines], [3, 2, 1]);
    expect(shown[0].names, ['Ruy']);
    expect(shown[0].here, isFalse);
    expect(shown[1].here, isTrue);
    expect(shown[0].goesOn, '3...a6 4.Ba4 Nf6 5.O-O');
    // The transposed file is found by position, and read along its own
    // move order.
    expect(shown[2].names, ['Knights']);
    expect(shown[2].places.single.sans, ['Nf3', 'Nc6', 'e4', 'e5', 'd4']);
    expect(tree.fileCount, 3);
  });

  test('the chapters of a course file are counted apart, each by its own '
      'lines', () async {
    const path = '/repertoires/Course/Course.pgn';
    fixture.store.documents[const DocumentRef(path)] = Opened(
      course,
      scriptedRevision(course),
    );
    files.listing = Repertoires([
      folder('e4', ['Italian']),
      RepertoireFolder(
        name: 'Course',
        path: '/repertoires/Course',
        modified: DateTime(2026),
        chapters: [
          ChapterRef.at(path, section: 'Scotch'),
          ChapterRef.at(path, section: 'Ruy'),
        ],
      ),
    ]);
    tree.forget();
    walk(['e4', 'e5', 'Nf3', 'Nc6']);
    await pumpEventQueue();
    final shown = rows();
    expect([for (final row in shown) row.san], ['Bb5', 'Bc4', 'd4']);
    expect([for (final row in shown) row.lines], [3, 2, 1]);
    expect(shown[0].names, ['Ruy']);
    expect(shown[0].places.single.ref, ChapterRef.at(path, section: 'Ruy'));
    expect(shown[2].names, ['Scotch']);
    expect(tree.fileCount, 3);
  });

  test('playing the chapter from the other side files it under that '
      'side', () async {
    setSide(fixture.session, Side.black);
    await pumpEventQueue();
    // The Italian, Black's now, plays 1.e4 beside the Najdorf.
    expect(rows().single.san, 'e4');
    expect(rows().single.lines, 3);
    expect(rows().single.names, ['Italian', 'Najdorf']);
    expect(tree.fileCount, 2);
  });

  test('files read again keep the moves on the free board', () async {
    walk(['e4', 'e5', 'Nf3', 'Nc6']);
    tree.play('f1b5');
    await pumpEventQueue();
    tree.forget();
    await pumpEventQueue();
    expect([for (final move in tree.offFile) move.san], ['Bb5']);
    expect(tree.board.value?.lastMove, 'f1b5');
    expect([for (final row in rows()) row.san], ['a6', 'Nf6', 'f5']);
  });

  test('a move on the free board reads the files first when another reader '
      'said they changed', () async {
    walk(['e4', 'e5', 'Nf3', 'Nc6']);
    await pumpEventQueue();
    // The book check reads the same shelf, and tells it, not the tree.
    shelf.forget();
    tree.play('f1b5');
    await pumpEventQueue();
    expect([for (final row in rows()) row.san], ['a6', 'Nf6', 'f5']);
  });

  test('a flipped board shows the other side\'s files', () async {
    fixture.session.flip();
    walk(['e4']);
    await pumpEventQueue();
    expect([for (final row in rows()) row.san], ['c5']);
    expect(rows().single.names, ['Najdorf']);
  });

  test('a move just played on the board is in the tree at once', () async {
    walk(['e4', 'e5', 'Nf3', 'Nc6', 'Bc4']);
    fixture.session.playMove('d7d6');
    await pumpEventQueue();
    fixture.session.goTo(fixture.session.cursor.parent);
    await pumpEventQueue();
    expect([
      for (final row in rows()) row.san,
    ], containsAll(['Bc5', 'Nf6', 'd6']));
  });

  test('says so where the repertoires have no move', () async {
    walk(['e4', 'e5', 'Nf3', 'Nc6', 'Bc4', 'Bc5', 'c3']);
    await pumpEventQueue();
    expect(tree.state, isA<TreeNothing>());
  });

  test('draft chapters are not lines the user plays', () async {
    files.listing = Repertoires([
      folder('e4', ['Italian']),
      RepertoireFolder(
        name: 'e4 draft',
        path: '/repertoires/e4 draft',
        modified: DateTime.now(),
        chapters: [
          ChapterRef(
            repertoire: 'e4',
            name: 'Ruy',
            path: chapterRef('e4', 'Ruy').path,
            heading: const ChapterHeading(rootMoves: [], draft: true),
          ),
        ],
      ),
    ]);
    tree.forget();
    walk(['e4', 'e5', 'Nf3', 'Nc6']);
    await pumpEventQueue();
    expect([for (final row in rows()) row.san], ['Bc4']);
  });

  test('a move the file does not play goes on the free board, not into '
      'the file', () async {
    walk(['e4', 'e5']);
    await pumpEventQueue();
    final before = fixture.session.tree;
    tree.play('g1f3');
    expect(fixture.session.currentMove!.san, 'Nf3', reason: 'in the file');
    expect(tree.board.value, isNull);
    tree.play('b8c6');
    expect(tree.offFile, isEmpty, reason: 'still in the file');
    // 3.Bb5 is only the Ruy's: played past the Italian, never written.
    tree.play('f1b5');
    await pumpEventQueue();
    expect(identical(fixture.session.tree, before), isTrue);
    expect(fixture.store.requestedSaves, isEmpty);
    expect(tree.board.value?.lastMove, 'f1b5');
    expect([for (final row in rows()) row.san], ['a6', 'Nf6', 'f5']);
    // A move nothing plays: the tree says so and the board keeps it.
    tree.play('h7h6');
    await pumpEventQueue();
    expect(tree.state, isA<TreeNothing>());
    expect([for (final m in tree.offFile) m.san], ['Bb5', 'h6']);
    tree.back();
    await pumpEventQueue();
    expect(rows(), hasLength(3));
    tree.back();
    expect(tree.board.value, isNull);
    expect(fixture.session.currentMove!.san, 'Nc6');
  });

  test('moving in the file or leaving the tab ends the free board', () async {
    walk(['e4', 'e5', 'Nf3', 'Nc6']);
    tree.play('f1b5');
    expect(tree.board.value, isNotNull);
    fixture.session.back();
    expect(tree.board.value, isNull);
    tree.play('g8f6');
    expect(tree.offFile, hasLength(1));
    tree.unwatch();
    expect(tree.board.value, isNull);
    expect(tree.offFile, isEmpty);
  });

  test('the engine analyses the free board while there is one', () async {
    final analysis = EngineAnalysis(
      fixture.session,
      () async => const StartFailed('no engine in this test'),
      elsewhere: tree.board,
    );
    addTearDown(analysis.dispose);
    walk(['e4', 'e5', 'Nf3', 'Nc6']);
    tree.play('f1b5');
    expect(analysis.position, tree.fen);
    expect(analysis.position, isNot(fixture.session.fen));
    tree.backToFile();
    expect(analysis.position, fixture.session.fen);
  });
}

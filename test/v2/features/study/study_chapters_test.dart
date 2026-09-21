import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/pgn/comment_text.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/chess/pgn/study.dart';
import 'package:chess_auto_prep/v2/features/study/study_commands.dart';
import 'package:chess_auto_prep/v2/storage/edit_scope.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

import '../../support/study_fixture.dart';

void main() {
  late StudyFixture study;

  Future<void> open({int chapter = 0, String text = twoChapterStudy}) async {
    study = await openStudy(text, chapter: chapter);
  }

  tearDown(() => study.dispose());

  test('opening a chapter: puts one game on the board, facing its own way', () async {
    await open(chapter: 1);
    expect(study.session.tree?.children.single.san, 'd4');
    expect(study.session.orientation, Side.black);
    expect(study.studies.openChapter, 1);
    expect(study.studies.chapters, hasLength(2));
  });

  test('opening a chapter: another chapter of the same file is another open', () async {
    await open();
    await study.session.open(study.ref, game: 1);
    expect(study.session.tree?.children.single.san, 'd4');
    expect(study.studies.openChapter, 1);
  });

  test('playing a move in a chapter: goes into that game as a variation, not a new chapter', () async {
    await open();
    study.session.goTo(const NodePath.root());
    study.session.playMove('d2d4');
    await pumpEventQueue();
    expect(study.studies.chapters, hasLength(2));
    expect(study.onDisk, contains('1. e4 (1. d4) e5'));
    expect(study.onDisk, contains('[ChapterName "Pawn endings"]'));
  });

  test('playing a move in a chapter: names only the game it wrote', () async {
    await open();
    study.session.playMove('e2e4');
    study.session.goTo(const NodePath.root());
    study.session.playMove('d2d4');
    await pumpEventQueue();
    final scope = study.store.requestedSaves.last.scope as GamesEdited;
    expect(scope.written.rewritten, {0});
    expect(scope.written.appended, 0);
  });

  test('chapter operations: a new chapter is added at the end and opened', () async {
    await open();
    expect(
      addStudyChapter(
        study.session,
        name: 'Bishop endings',
        orientation: Side.black,
      ),
      isNull,
    );
    await pumpEventQueue();
    expect(study.studies.chapters.map((c) => c.name).last, 'Bishop endings');
    expect(study.studies.openChapter, 2);
    expect(study.onDisk, contains('[ChapterName "Bishop endings"]'));
    expect(study.onDisk, contains('1. e4 e5 2. Nf3 *'));
  });

  test('chapter operations: a chapter from a FEN carries its position', () async {
    await open();
    const fen = '4k3/8/8/8/8/8/4P3/4K3 b - - 0 1';
    addStudyChapter(
      study.session,
      name: 'Mate in one',
      orientation: Side.black,
      root: const Fen(fen),
    );
    await pumpEventQueue();
    expect(study.onDisk, contains('[FEN "$fen"]'));
    expect(study.session.fen, const Fen(fen));
  });

  test('chapter operations: a FEN that is not a position is refused, and nothing changes',
      () async {
    await open();
    final before = study.onDisk;
    expect(
      addStudyChapter(
        study.session,
        name: 'Broken',
        orientation: Side.white,
        root: const Fen('not a position'),
      ),
      contains('cannot be written'),
    );
    await pumpEventQueue();
    expect(study.onDisk, before);
  });

  test('chapter operations: renaming writes the study tags and keeps the others', () async {
    await open();
    expect(
      renameStudyChapter(study.session, index: 0, name: 'Rooks'),
      isNull,
    );
    await pumpEventQueue();
    expect(study.onDisk, contains('[ChapterName "Rooks"]'));
    expect(study.onDisk, contains('[Event "Endgames: Rooks"]'));
    expect(study.onDisk, contains('[Result "*"]'));
    expect(study.onDisk, contains('[ChapterName "Pawn endings"]'));
  });

  test('chapter operations: setting the orientation turns the open board', () async {
    await open();
    expect(study.session.orientation, Side.white);
    setStudyChapterOrientation(
      study.session,
      index: 0,
      orientation: Side.black,
    );
    await pumpEventQueue();
    expect(study.session.orientation, Side.black);
    expect(study.onDisk, contains('[Orientation "black"]'));
  });

  test('chapter operations: moving a chapter down reorders the games and follows it', () async {
    await open();
    expect(moveStudyChapter(study.session, index: 0, by: 1), isNull);
    await pumpEventQueue();
    expect(study.studies.chapters.map((c) => c.name), [
      'Pawn endings',
      'Rook endings',
    ]);
    expect(study.studies.openChapter, 1);
    final scope = study.store.requestedSaves.last.scope as GamesReordered;
    expect(scope.from, [1, 0]);
  });

  test('chapter operations: a chapter already first will not move up', () async {
    await open();
    expect(
      moveStudyChapter(study.session, index: 0, by: -1),
      'That chapter is already first.',
    );
    expect(study.store.requestedSaves, isEmpty);
  });

  test('chapter operations: deleting a chapter leaves the others byte for byte', () async {
    await open(chapter: 1);
    expect(deleteStudyChapter(study.session, index: 0), isNull);
    await pumpEventQueue();
    expect(study.studies.chapters.map((c) => c.name), ['Pawn endings']);
    expect(study.onDisk, isNot(contains('Rook endings')));
    expect(study.onDisk, contains('1. d4 d5 *'));
    final scope = study.store.requestedSaves.last.scope as GamesReordered;
    expect(scope.from, [1]);
  });

  test('chapter operations: the last chapter cannot be deleted', () async {
    await open(
      text: '[Event "Solo: Only"]\n[ChapterName "Only"]\n\n1. e4 *\n',
    );
    expect(
      deleteStudyChapter(study.session, index: 0),
      'A study needs at least one chapter.',
    );
    expect(study.store.requestedSaves, isEmpty);
  });

  test('quiz markers: marking a move writes a token and keeps the words', () async {
    await open();
    study.session.setComment(NodePath.of(const [0]), 'the main move');
    await pumpEventQueue();
    study.session.setMarker(
      NodePath.of(const [0]),
      quizStartMarker,
      on: true,
    );
    await pumpEventQueue();
    expect(study.onDisk, contains('{the main move [%tstart]}'));
    final comment = study.session.commentAt(NodePath.of(const [0]));
    expect(hasToken(comment, quizStartMarker), isTrue);
    expect(displayComment(comment!), 'the main move');
  });

  test('quiz markers: unmarking takes the token away and leaves the words', () async {
    await open();
    study.session.setComment(NodePath.of(const [0]), 'the main move');
    study.session.setMarker(
      NodePath.of(const [0]),
      quizEndMarker,
      on: true,
    );
    await pumpEventQueue();
    study.session.setMarker(
      NodePath.of(const [0]),
      quizEndMarker,
      on: false,
    );
    await pumpEventQueue();
    expect(study.onDisk, contains('{the main move}'));
    expect(study.onDisk, isNot(contains('tend')));
  });

  test('quiz markers: a marker on a move with no words is a comment of its own', () async {
    await open();
    study.session.setMarker(
      NodePath.of(const [0]),
      quizStartMarker,
      on: true,
    );
    await pumpEventQueue();
    expect(study.onDisk, contains('{[%tstart]}'));
    expect(displayComment('[%tstart]'), isEmpty);
  });
}

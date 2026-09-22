// Lines move between chapters as whole games: dropped on a chapter a line
// becomes a game of its own there, dropped on a line it becomes that game's
// sidelines. The rule under all of it is that no game nobody named keeps
// anything but its own bytes.
import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/pgn/chapter_edit.dart';
import 'package:chess_auto_prep/v2/chess/pgn/line_moves.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

Chapter white() => parseChapter(name: 'Gambit', text: whiteChapter);

Chapter black() => parseChapter(name: 'Sicilian', text: blackChapter);

Chapter empty() => parseChapter(name: 'Sidelines', text: emptyChapter);

Chapter oneGame(String text) => parseChapter(name: 'One', text: text);

ChapterEdited edited(ChapterEdit edit) => edit as ChapterEdited;

String refusal(ChapterEdit edit) => (edit as ChapterEditRefused).reason;

List<String> texts(Chapter chapter) => [
  for (final line in chapter.lines) line.text,
];

/// The chapter written out and read back: what the store would put on disk,
/// and what opening the file again gives.
Chapter onDisk(Chapter chapter) => parseChapter(
  name: chapter.name,
  text: writeChapter(chapter),
  game: chapter.game,
);

/// A game the first game of [whiteChapter] already plays every move of.
const _prefix =
    '[Event "Short"]\n'
    '[Result "*"]\n'
    '\n'
    '1. d4 d5 2. c4 e6 *\n';

/// A game with a `[FEN]` that is not a position, so nothing could read it.
const _unreadable =
    '[Event "Broken"]\n'
    '[FEN "not a fen"]\n'
    '[SetUp "1"]\n'
    '\n'
    '1. e4 *\n';

/// A game with an illegal move in it, so it keeps its own bytes.
const _partial =
    '[Event "Partial"]\n'
    '[Result "*"]\n'
    '\n'
    '1. d4 d5 2. Ke3 Nf6 *\n';

const _fromAnotherPosition = 'that line starts from another position';

const _nothingCouldRead = 'a line nothing could read cannot be moved';

void main() {
  test('taking lines out leaves the others byte for byte', () {
    final before = white();

    final after = edited(linesTakenOut(before, games: {0, 2}));

    expect(texts(after.chapter), [before.lines[1].text]);
    expect(after.games.order, [1]);
    expect(after.games.rewritten, isEmpty);
    expect(after.games.before, 3);
  });

  test('the file taking lines out produces reads back as the chapter it '
      'made', () {
    final after = edited(linesTakenOut(white(), games: {1}));

    expect(texts(onDisk(after.chapter)), texts(after.chapter));
    expect(writeChapter(after.chapter), startsWith("// Queen's Gambit\n"));
  });

  test('a set that names no game of the file changes nothing', () {
    expect(linesTakenOut(white(), games: {}), isA<ChapterUnchanged>());
    expect(linesTakenOut(white(), games: {7, -1}), isA<ChapterUnchanged>());
  });

  test('a study may not lose its last chapter', () {
    final study = parseChapter(name: 'Study', text: whiteChapter, game: 0);

    expect(
      refusal(linesTakenOut(study, games: {0, 1, 2})),
      'a study needs at least one chapter',
    );
  });

  test('the board stays on the chapter it was on', () {
    final study = parseChapter(name: 'Study', text: whiteChapter, game: 2);

    final after = edited(linesTakenOut(study, games: {0}));

    expect(after.chapter.game, 1);
    expect(showingGameText(after.chapter), study.lines[2].text);
  });

  test('the board moves to what took the place of the chapter taken', () {
    final study = parseChapter(name: 'Study', text: whiteChapter, game: 1);

    final after = edited(linesTakenOut(study, games: {1}));

    expect(showingGameText(after.chapter), study.lines[2].text);
  });

  test('a line added to a chapter arrives as a game of its own, byte for '
      'byte', () {
    final source = white().lines[1];
    final target = edited(linesTakenOut(white(), games: {1, 2})).chapter;

    final after = edited(linesAddedTo(target, lines: [source]));

    expect(texts(after.chapter), [target.lines[0].text, source.text]);
    expect(after.games.order, [0, null]);
    expect(after.games.rewritten, isEmpty);
    expect(after.games.before, 1);
    expect(texts(onDisk(after.chapter)), texts(after.chapter));
  });

  test('a line whose id the chapter already has gets one of its own', () {
    final source = white().lines[1];

    final after = edited(linesAddedTo(white(), lines: [source]));

    final added = after.chapter.lines[3];
    expect(added.lineId, isNot(source.lineId));
    // Only that one header reads differently; every other tag and every byte
    // of the moves came through.
    expect(added.text.replaceAll(added.lineId!, source.lineId!), source.text);
    expect(texts(after.chapter).take(3), texts(white()));
    expect(after.games.order, [0, 1, 2, null]);
    expect(texts(onDisk(after.chapter)), texts(after.chapter));
  });

  test('an empty chapter keeps its heading and takes the lines under it', () {
    final source = white();

    final after = edited(
      linesAddedTo(empty(), lines: [source.lines[0], source.lines[1]]),
    );

    expect(after.chapter.preamble, emptyChapter);
    expect(texts(after.chapter), [source.lines[0].text, source.lines[1].text]);
    expect(after.games.order, [null, null]);
    expect(after.games.before, 0);
    expect(writeChapter(after.chapter), startsWith(emptyChapter));
    expect(texts(onDisk(after.chapter)), texts(after.chapter));
  });

  test('a line from another position is not added to the chapter', () {
    expect(
      refusal(linesAddedTo(white(), lines: [black().lines[0]])),
      _fromAnotherPosition,
    );
  });

  test('a line nothing could read is not added to the chapter', () {
    expect(
      refusal(linesAddedTo(white(), lines: [oneGame(_unreadable).lines[0]])),
      _nothingCouldRead,
    );
  });

  test('no lines is no edit', () {
    expect(linesAddedTo(white(), lines: []), isA<ChapterUnchanged>());
  });

  test('a grafted line becomes a variation where the two games part', () {
    final before = white();

    final after = edited(
      lineGraftedInto(before, host: 0, line: before.lines[1]),
    );

    final host = after.chapter.lines[0].text;
    expect(host, contains('2... c6'));
    expect(host, contains('The Slav'));
    expect(host, contains('3. Nf3'));
    expect(after.games.rewritten, {0});
    expect(after.games.order, [0, 1, 2]);
    expect(texts(onDisk(after.chapter)), texts(after.chapter));
  });

  test('grafting keeps the host its own moves, comments and variations', () {
    final before = white();

    final after = edited(
      lineGraftedInto(before, host: 0, line: before.lines[1]),
    );

    final host = after.chapter.lines[0].text;
    expect(host, contains('{Our repertoire against 1... d5.}'));
    expect(host, contains('{[%eval 0.21] [%clk 0:29:41]}'));
    expect(host, contains(r'3... Nf6 $6 {Rarely played.}'));
    expect(host, contains('[LineID "line_MS4gZDQgZDUgMi4gYzQ"]'));
    expect(host, endsWith('4. Nc3 *'));
  });

  test('the games beside a grafted host keep their bytes', () {
    final before = white();

    final after = edited(
      lineGraftedInto(before, host: 0, line: before.lines[1]),
    );

    expect(after.chapter.lines[1].text, before.lines[1].text);
    expect(after.chapter.lines[2].text, before.lines[2].text);
  });

  test('a line the host already plays every move of writes nothing', () {
    expect(
      lineGraftedInto(white(), host: 0, line: oneGame(_prefix).lines[0]),
      isA<ChapterUnchanged>(),
    );
  });

  test('a line from another position is not grafted', () {
    expect(
      refusal(lineGraftedInto(white(), host: 0, line: black().lines[0])),
      _fromAnotherPosition,
    );
  });

  test('a line nothing could read is not grafted', () {
    expect(
      refusal(
        lineGraftedInto(white(), host: 0, line: oneGame(_unreadable).lines[0]),
      ),
      _nothingCouldRead,
    );
  });

  test('a host that was not read whole keeps its bytes', () {
    final edit = lineGraftedInto(
      oneGame(_partial),
      host: 0,
      line: oneGame(_prefix).lines[0],
    );

    expect(refusal(edit), lineNotWholeReason);
  });

  test('a host the file does not have changes nothing', () {
    expect(
      lineGraftedInto(white(), host: 9, line: oneGame(_prefix).lines[0]),
      isA<ChapterUnchanged>(),
    );
  });
}

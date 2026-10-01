import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/pgn/chapter_line.dart';
import 'package:chess_auto_prep/chess/pgn/game_text.dart';
import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/chess/pgn/pgn_reader.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/big_chapter.dart';
import '../../support/fixtures.dart';

/// Everything a line holds, as text two readings can be compared by.
String _held(ChapterLine line) => [
  for (final tag in line.tags) '${tag.text}${tag.trailer}',
  line.separator,
  for (final node in line.tree?.mainLine ?? const <MoveNode>[])
    '${node.san} ${node.spelling} ${node.uci} ${node.fen.value} '
        '${node.comment} ${node.nags}',
  '${line.terminator}',
  '${line.issues}',
  line.text,
  line.trailer,
].join('\n');

ChapterLine _unread(String text) =>
    ChapterLine.unread(tags: readHeaders(text), text: text, trailer: '\n');

const _game = '[Event "One"]\n[Result "1-0"]\n\n1. e4 {best} e5 2. Nf3 1-0';

void main() {
  /// Larger than a read on this isolate goes, with a game nothing can read
  /// and one with a move nobody can play among the rest.
  final large =
      '${bigChapter(games: 1500)}'
      '[Event "Broken"]\n[FEN "not a fen"]\n\n1. e4 *\n\n'
      '[Event "Illegal"]\n\n1. e4 e5 2. Ke3 Nf6 *\n';

  test('a large file read showing one game holds what the whole read '
      'holds', () async {
    expect(large.length, greaterThan(readOffThreadFrom));
    final whole = parseChapter(name: 'Book', text: large, game: 3);
    final shown = await readChapterShowing(name: 'Book', text: large, game: 3);
    expect(shown.name, whole.name);
    expect(shown.game, 3);
    expect(shown.side, whole.side);
    expect(shown.preamble, whole.preamble);
    expect(writeChapter(shown), large);
    expect(shown.lines, hasLength(whole.lines.length));
    await movesBeingRead(shown.lines);
    for (final (index, line) in shown.lines.indexed) {
      expect(_held(line), _held(whole.lines[index]), reason: 'game $index');
    }
    expect(shown.lines[1500].tree, isNull);
    expect(shown.lines[1501].isWhole, isFalse);
  });

  test('the game on the board is read without waiting for the others, and '
      'keeps the moves it read when theirs arrive', () async {
    final shown = await readChapterShowing(name: 'Book', text: large, game: 3);
    final tree = shown.tree;
    expect(tree, same(shown.lines[3].tree));
    expect(tree.mainLine, hasLength(16));
    final arriving = movesBeingRead(shown.lines);
    await arriving;
    expect(shown.lines.every((line) => line.isRead), isTrue);
    expect(shown.lines[3].tree, same(tree));
    expect(movesBeingRead(shown.lines), isNull);
  });

  test('another game of the file is shown over the same games', () async {
    final shown = await readChapterShowing(name: 'Book', text: large, game: 0);
    final next = withGame(shown, 7);
    expect(next.lines, same(shown.lines));
    expect(next.tree, same(shown.lines[7].tree));
    await movesBeingRead(shown.lines);
  });

  test('a small file is read whole at once', () async {
    final shown = await readChapterShowing(
      name: 'Main',
      text: blackChapter,
      game: 0,
    );
    expect(shown.lines.every((line) => line.isRead), isTrue);
    expect(movesBeingRead(shown.lines), isNull);
  });

  group('a game whose moves are not read yet', () {
    test('has its headers, and reads the rest when asked', () {
      final line = _unread(_game);
      expect(line.isRead, isFalse);
      expect(tagValue(line.tags, 'Event'), 'One');
      expect(line.isRead, isFalse);
      expect(
        [for (final node in line.tree!.mainLine) node.san],
        ['e4', 'e5', 'Nf3'],
      );
      expect(line.isRead, isTrue);
      expect(line.terminator, '1-0');
      expect(line.separator, '\n');
      expect(line.issues, isEmpty);
    });

    test('has the headers the whole read gives', () {
      for (final text in [
        _game,
        '[Event "A"] [Site "B"]\r\n[Round "1"]\n% an escape\n\n1. d4 *',
        '[Event "No moves"]',
        '[Event "Moves on the header line"] 1. e4 *',
      ]) {
        final headers = [
          for (final tag in readHeaders(text)) '${tag.text}|${tag.trailer}',
        ];
        final whole = [
          for (final tag in readGame(text).tags) '${tag.text}|${tag.trailer}',
        ];
        expect(headers, whole, reason: text);
      }
    });

    test('takes a reading done elsewhere, once', () {
      final line = _unread(_game);
      final first = readGame(_game);
      line.take(first);
      expect(line.isRead, isTrue);
      expect(line.tree, same(first.tree));
      line.take(readGame(_game));
      expect(line.tree, same(first.tree));
    });

    test('keeps the moves it read itself when a reading arrives', () {
      final line = _unread(_game);
      final own = line.tree;
      line.take(readGame(_game));
      expect(line.tree, same(own));
    });

    test('moved to another place in the file is still not read', () {
      final line = _unread(_game);
      final moved = line.spacedBy('\n\n');
      expect(moved.isRead, isFalse);
      expect(line.isRead, isFalse);
      expect(moved.trailer, '\n\n');
      expect(moved.terminator, '1-0');
    });
  });
}

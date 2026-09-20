import 'dart:io';
import 'dart:math';

import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_text.dart';
import 'package:chess_auto_prep/v2/chess/pgn/pgn_issue.dart';
import 'package:chess_auto_prep/v2/chess/pgn/pgn_reader.dart';
import 'package:flutter_test/flutter_test.dart';

/// Characters that have a meaning somewhere in the format, so a mutation is
/// far likelier to reach a decision than a random byte would be.
const _poison =
    r'[]{}();%$"\*.-+#=xXzZ0189abhqQKNO '
    '\n\r\t﻿';

String fixture(String name) =>
    File('test/fixtures/v2_pgn/$name').readAsStringSync();

/// [text] with one character replaced.
String mutated(String text, Random random) {
  final at = random.nextInt(text.length);
  final with_ = _poison[random.nextInt(_poison.length)];
  return text.replaceRange(at, at + 1, with_);
}

/// Two games whose braces do not balance line by line, because only the
/// movetext can open a comment.
const _bracedTag =
    '[Event "a {b"]\n'
    '[Result "*"]\n'
    '\n'
    '1. e4 *\n'
    '\n'
    '[Event "B"]\n'
    '[Result "*"]\n'
    '\n'
    '1. d4 *\n';

const _bracedNote =
    '[Event "A"]\n'
    '[Result "*"]\n'
    '\n'
    '1. e4 ; a note with a { in it\n'
    '*\n'
    '\n'
    '[Event "B"]\n'
    '[Result "*"]\n'
    '\n'
    '1. d4 *\n';

/// A comment nobody closes, which only a `;` comment can carry a `}` into.
const _braceInNote = '1. e4 ; careful } here\ne5 *';

void main() {
  test('a position nobody can read is reported, not thrown', () {
    // dartchess answers this one with a bare ArgumentError out of the board
    // parser — "Invalid argument(s): -2" — rather than with a FEN exception.
    const game =
        '[FEN "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/.NBQKBNR w KQkq - 0 1"]\n'
        '\n'
        '1. e4 *';
    final read = readGame(game);
    expect(read.tree, isNull);
    expect(read.issues.single, isA<UnreadablePosition>());
    expect(read.issues.single.line, 1);
  });

  test('a capture with nothing in front of it is reported, not thrown', () {
    // The token reaches dartchess as an empty string once it cuts the
    // annotation off, and dartchess reads its first character.
    final read = readGame('1. xe4 e5 *');
    expect(read.issues.first, isA<UnknownToken>());
    expect(read.rewritable, isFalse);
  });

  test('a move in long algebraic is reported, not played', () {
    final read = readGame('1. e2-e4 *');
    expect(read.issues.single, isA<IllegalMove>());
  });

  test('a comment holding a closing brace is named at read', () {
    // Only a `;` comment can carry one, and no `{}` comment can be written
    // to hold it.
    final read = readGame(_braceInNote);
    expect(read.issues.single, isA<CommentHoldsBrace>());
    expect(read.rewritable, isFalse);
  });

  test('an empty comment is written back as an empty comment', () {
    final read = readGame('[Event "A"]\n\n1. e4 {} e5 *');
    expect(read.tree!.children.single.comment, isEmpty);
    expect(read.issues, isEmpty);
    expect(
      writeGameText(
        read.tags,
        read.tree!,
        terminator: read.terminator,
        separator: read.separator,
      ),
      '[Event "A"]\n\n1. e4 {} e5 *',
    );
  });

  test('a brace in a tag value does not swallow the games below it', () {
    final chapter = parseChapter(name: 'Braced', text: _bracedTag);
    expect(chapter.lines, hasLength(2));
    expect(chapter.issues, isEmpty);
    expect(writeChapter(chapter), _bracedTag);
  });

  test('a brace after a semicolon does not swallow the games below it', () {
    final chapter = parseChapter(name: 'Semicolons', text: _bracedNote);
    expect(chapter.lines, hasLength(2));
  });

  group('one character changed anywhere in a real file', () {
    for (final name in const ['lichess_study.pgn', 'chessable_course.pgn']) {
      test('$name still reads as something, 1500 times over', () {
        final text = fixture(name);
        final random = Random(name.hashCode);
        for (var i = 0; i < 1500; i++) {
          final broken = mutated(text, random);
          expect(
            () => writeChapter(parseChapter(name: name, text: broken)),
            returnsNormally,
            reason: 'mutation $i of $name',
          );
        }
      });
    }
  });
}

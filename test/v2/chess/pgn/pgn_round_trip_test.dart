import 'dart:io';

import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/chess/pgn/pgn_reader.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/pgn_round_trip.dart';

/// Hand-written files in the shapes the app actually meets. Each one must
/// come back byte for byte, and each game in it must survive being written
/// again from what reading it gave.
///
/// Nothing here is named `twic*.pgn`: `.gitignore` drops those as scratch
/// downloads, and a fixture the repository does not hold is a test that
/// passes for whoever wrote it and nobody else.
const _dialects = [
  'lichess_study.pgn',
  'chessable_course.pgn',
  'chessbase.pgn',
  'chesscom.pgn',
  'tournament_bulletin.pgn',
  'old_app_chapter.pgn',
  'dialects.pgn',
];

/// Every file the fixture folder is expected to hold, so one the repository
/// does not track is named here rather than found missing much later.
const _fixtures = [..._dialects, 'malformed.pgn'];

String fixture(String name) =>
    File('test/fixtures/v2_pgn/$name').readAsStringSync();

/// One game per part of the grammar, each holding the part its key names.
const _games = {
  'plain moves': '1. e4 e5 2. Nf3 Nc6 *',
  'a comment before the first move': '{Why} 1. e4 *',
  'a comment after a move': '1. e4 {King pawn} e5 *',
  'a comment with padding': '1. e4 { spaced } *',
  'a comment holding a brace': '1. e4 {see {this} *',
  'a comment holding a newline': '1. e4 {one\ntwo} e5 *',
  'machine tokens': '1. e4 {[%eval 0.2] [%clk 0:29:41] [%cal Ge2e4]} *',
  'an unknown machine token': '1. e4 {[%myEase 2.5] [%score 46.4%]} *',
  'a numeric annotation': r'1. e4 $1 e5 $14 *',
  'annotations that only a file writes': r'1. e4 $132 $146 *',
  'a variation': '1. e4 e5 (1... c5 2. Nf3) 2. Nf3 *',
  'a variation with a note before it': '1. e4 ({A note} 1. d4 d5) e5 *',
  'variations nested four deep':
      '1. e4 (1. d4 (1. c4 (1. Nf3 (1. g3 d5)))) e5 *',
  'two variations of one move': '1. e4 (1. d4) (1. c4) e5 *',
  'a null move': '{Introduction} 1. -- *',
  'a null move with a variation': '1. Z0 (1. d4 d5) e5 *',
  'castling both ways':
      '[FEN "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1"]\n\n1. O-O O-O-O *',
  'castling written with zeros':
      '[FEN "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1"]\n\n1. 0-0 0-0-0 *',
  'a promotion': '[FEN "8/4P3/8/8/8/8/6k1/K7 w - - 0 60"]\n\n60. e8=Q *',
  'a promotion with no equals sign':
      '[FEN "8/4P3/8/8/8/8/6k1/K7 w - - 0 60"]\n\n60. e8Q *',
  'a mate': '1. e4 e5 2. Bc4 Nc6 3. Qh5 Nf6 4. Qxf7# 1-0',
  'an over-precise disambiguation': '1. e4 e5 2. Ngf3 *',
  'en passant spelled out': '1. e4 d5 2. e5 f5 3. exf6 e.p. *',
  'a rest-of-line comment': '1. e4 ; a thought\ne5 *',
  'a starting position': '[FEN "8/8/8/8/8/8/8/K6k w - - 0 1"]\n\n1. Kb1 *',
  'a five-digit move number': '10000. e4 10000... e5 *',
  'no termination marker': '[Event "A"]\n\n1. e4 e5',
  'a marker the Result tag disagrees with': '[Result "*"]\n\n1. e4 1-0',
  'a tag value with an escaped quote': '[White "He said \\"go\\""]\n\n1. e4 *',
  'a tag value with a backslash': '[Site "C:\\\\games"]\n\n1. e4 *',
  'a tag named twice': '[Result "1-0"]\n[Result "0-1"]\n\n1. e4 1-0',
  'header lines ending in CRLF': '[Event "A"]\r\n[Result "*"]\r\n\n1. e4 *',
  'text that is not ASCII': '[White "Böhm, Ö"]\n\n1. e4 {½ → ∞ ♞} *',
  'a private-use glyph in a comment': '1. e4 {a \ue02d glyph} *',
};

/// A game the writer spells its own way, and how it spells it.
const _normalised = {
  '1. e4 1... e5 2. Nf3 *': '1. e4 e5 2. Nf3 *',
  '1.e4 e5': '1. e4 e5',
  '1. e4 {a} {b} *': '1. e4 {a b} *',
  '1. e4!? *': r'1. e4 $5 *',
  '1. e4 d5 2. e5 f5 3. exf6 e.p. *': '1. e4 d5 2. e5 f5 3. exf6 *',
  '1. e4 ; a thought\ne5 *': '1. e4 { a thought} e5 *',
};

void main() {
  test('the fixture folder holds exactly the files the tests name', () {
    final found = Directory(
      'test/fixtures/v2_pgn',
    ).listSync().map((entry) => entry.uri.pathSegments.last).toList();
    expect(found..sort(), [..._fixtures]..sort());
  });

  group('a game with the part named survives being written again', () {
    for (final entry in _games.entries) {
      test(entry.key, () => expectRoundTrip(entry.value));
    }
  });

  group('a game the writer spells its own way still says the same', () {
    for (final entry in _normalised.entries) {
      test('${entry.key} becomes ${entry.value}', () {
        expect(written(readGame(entry.key)), entry.value);
        expectRoundTrip(entry.key);
      });
    }
  });

  group('the files the app meets', () {
    for (final name in _dialects) {
      test('$name comes back byte for byte', () {
        final text = fixture(name);
        expect(writeChapter(parseChapter(name: name, text: text)), text);
      });

      test('every game of $name can be written again', () {
        final chapter = parseChapter(name: name, text: fixture(name));
        expect(chapter.issues, isEmpty);
        expect(chapter.lines, isNotEmpty);
        for (final line in chapter.lines) {
          expect(line.isWhole, isTrue, reason: line.text);
          expectRoundTrip(line.text);
        }
      });
    }

    test('a file with a byte-order mark keeps it', () {
      final text = '\uFEFF${fixture('tournament_bulletin.pgn')}';
      final chapter = parseChapter(name: 'BOM', text: text);
      expect(chapter.lines, hasLength(2));
      expect(writeChapter(chapter), text);
    });
  });

  group('the malformed file', () {
    final chapter = parseChapter(
      name: 'malformed.pgn',
      text: fixture('malformed.pgn'),
    );

    test('reports every game and keeps all of their bytes', () {
      expect(chapter.lines, hasLength(6));
      for (final line in chapter.lines) {
        expect(line.isWhole, isFalse, reason: line.text);
      }
      expect(writeChapter(chapter), fixture('malformed.pgn'));
    });

    test('says what is wrong with each game and where', () {
      expect(
        [
          for (final line in chapter.lines)
            '${chapter.lines.indexOf(line)}: ${line.issues.first.detail}',
        ],
        [
          '0: Ke3 is not a legal move here',
          '1: a variation with no move in it',
          '2: a % escape line among the moves',
          '3: "zzz" is not anything a game can hold',
          '4: the FEN header is not a position',
          '5: a comment was never closed',
        ],
      );
    });
  });

  test('a comment holding a closing brace cannot be written and says so', () {
    // No PGN reader gives `}` a meaning other than "the comment ends here",
    // and neither the old app nor Lichess escapes it — both strip braces
    // instead. So a `}` the user types is text the writer cannot say, and
    // the gate refuses rather than quietly dropping it.
    const game = '1. e4 *';
    final tree = readGame(game).tree!;
    expect(
      refusal(
        game,
        GameTree(
          rootFen: tree.rootFen,
          children: [tree.children.single.copyWith(comment: 'a } b')],
        ),
      ),
      isNotNull,
    );
  });
}

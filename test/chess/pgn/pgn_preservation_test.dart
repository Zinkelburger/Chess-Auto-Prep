/// What the player wrote in a PGN file survives the app reading and writing
/// it, over every file the fixture folders hold, games built through the
/// model from fixed seeds, course files edited the way the workspace edits
/// them, and hostile but legal text.
///
/// The laws, each checked game by game:
///
/// 1. read, write, read gives the same game: every header line in order
///    (unknown tags included), every move and variation at any depth, every
///    comment before and after a move with its `[%…]` tokens, every NAG,
///    the result and the starting position;
/// 2. writing what was read from the writer's own output gives the same
///    bytes;
/// 3. a course keeps each game's `[ChapterName]` and `[LineID]`, and an edit
///    to one chapter leaves every game outside it byte for byte;
/// 4. hostile text neither throws nor hangs, and comes back byte for byte.
///
/// Every generated case is a fixed seed; a failure prints it and the
/// smallest case that still fails (`test/support/props.dart`).
library;

import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/pgn/chapter_line.dart';
import 'package:chess_auto_prep/chess/pgn/chapter_sections.dart';
import 'package:chess_auto_prep/chess/pgn/game_text.dart';
import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/chess/pgn/line_id_pins.dart';
import 'package:chess_auto_prep/chess/pgn/pgn_reader.dart';
import 'package:chess_auto_prep/chess/pgn/reading_place.dart';
import 'package:chess_auto_prep/chess/pgn/rewrite_gate.dart';
import 'package:chess_auto_prep/chess/pgn/tree_edit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/gen/edit_gen.dart';
import '../../support/gen/game_cases.dart';
import '../../support/gen/tree_gen.dart';
import '../../support/pgn_round_trip.dart';
import '../../support/props.dart';
import '../../support/viewer_fixture.dart';

/// The folders whose every file these laws run over.
const _pgnFolder = 'test/fixtures/pgn';
const _commentFolder = 'test/fixtures/comments';
const _legacyFolder = 'test/fixtures/legacy';

/// The legacy files, and what each holds. Only the viewer's game keys
/// describe PGN games; the rating oracle is numbers for the tournament
/// code and is named here so a new legacy file is a decision, not a gap.
const _legacy = {
  'viewer_game_keys.json': 'the keys the old viewer saved games under',
  'rating_reports.json': 'rating numbers, no PGN',
};

List<File> _filesIn(String folder) =>
    Directory(folder).listSync().whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));

void main() {
  group('every PGN fixture', () {
    for (final file in _filesIn(_pgnFolder)) {
      final name = p.basename(file.path);
      test('$name: every game read whole is written again as itself', () {
        final text = file.readAsStringSync();
        final chapter = parseChapter(name: name, text: text);
        expect(writeChapter(chapter), text, reason: 'the file');
        for (final (index, line) in chapter.lines.indexed) {
          if (!line.isWhole) continue;
          expectSameGameWritten(line.text, '$name game $index');
          expectKeyKept(line, '$name game $index');
        }
      });
    }
  });

  group('every comment fixture', () {
    for (final file in _filesIn(_commentFolder)) {
      final name = p.basename(file.path);
      final comment = file.readAsStringSync();

      test('$name as an introduction, a note and a note before a move', () {
        final e4 = readGame('1. e4 (1. d4) *').tree!;
        final tree = GameTree(
          rootFen: Fen.initial,
          rootComment: comment,
          children: [
            e4.children.first.copyWith(comment: comment),
            e4.children.last.copyWith(startingComment: comment),
          ],
        );
        final text = writeGameText(
          const [PgnTag('Event', 'Comment')],
          tree,
          terminator: '*',
          separator: '\n',
        );
        final read = readGame(text);
        expect(read.issues, isEmpty);
        expect(treeDifference(read.tree!, tree), isNull);
        expectSameGameWritten(text, name);
      });

      test('$name typed into a file comes back byte for byte', () {
        final text = '[Event "Comment"]\n\n{$comment} 1. e4 {$comment} *\n';
        expect(writeChapter(parseChapter(name: name, text: text)), text);
        expectSameGameWritten(text.trimRight(), name);
      });
    }
  });

  group('every legacy fixture', () {
    test('the folder holds the files named here', () {
      expect([
        for (final file in _filesIn(_legacyFolder)) p.basename(file.path),
      ], [..._legacy.keys]..sort());
    });

    test('a game rewritten keeps the key the old viewer saved it under', () {
      final stored =
          jsonDecode(
                File(
                  p.join(_legacyFolder, 'viewer_game_keys.json'),
                ).readAsStringSync(),
              )
              as List;
      final chapter = parseChapter(
        name: '',
        text: '$threeGameFile\n$oddlySpelledGame',
      );
      expect([for (final line in chapter.lines) readingGameKey(line)], stored);
      for (final (index, line) in chapter.lines.indexed) {
        expectKeyKept(line, 'game $index');
      }
    });
  });

  group('games built through the model', () {
    test(
      'the generator reaches deep variations, set-up positions and tags',
      () {
        var deep = 0;
        var setUp = 0;
        var crlf = 0;
        var chapterTags = 0;
        for (var i = 0; i < 200; i++) {
          final game = gameCases.sample(Rand(defaultPropSeed + i)).game;
          if (_deepest(game.tree) >= 30) deep++;
          if (tagValue(game.tags, 'FEN') != null) setUp++;
          if (game.text.contains('\r\n')) crlf++;
          if (tagValue(game.tags, 'LineID') != null) chapterTags++;
        }
        expect(deep, greaterThan(10));
        expect(setUp, greaterThan(50));
        expect(crlf, greaterThan(20));
        expect(chapterTags, greaterThan(50));
      },
    );

    forAll('1 read, write, read gives the same game', gameCases, (c) {
      final game = c.game;
      final read = readGame(game.text);
      expect(read.issues, isEmpty);
      expect(_tags(read.tags), _tags(game.tags));
      expect(treeDifference(read.tree!, game.tree), isNull);
      expect(_tokens(read.tree!), _tokens(game.tree));
      expect(read.terminator, game.terminator);
      expect(read.separator, game.separator);
    });

    forAll('2 the writer\'s own output is a fixed point', gameCases, (c) {
      final game = c.game;
      final once = written(readGame(game.text));
      expect(once, game.text);
      expect(written(readGame(once)), once);
      expect(refusal(game.text), isNull);
    });

    forAll(
      '3 a chapter of them keeps each game\'s chapter name and line id',
      listOf(gameCases, min: 1, max: 5),
      (cases) {
        final games = [for (final c in cases) c.game];
        final text = '${games.map((g) => g.text).join('\n\n')}\n';
        final chapter = parseChapter(name: 'Generated', text: text);
        expect(writeChapter(chapter), text);
        expect(chapter.lines, hasLength(games.length));
        for (final (index, game) in games.indexed) {
          final line = chapter.lines[index];
          final reason = 'game $index';
          // A game with nothing below its header gives the whitespace after
          // its last tag to the gap before the next game; writeChapter above
          // shows those bytes are all still there.
          expect(
            _tags(line.tags, trailers: false),
            _tags(game.tags, trailers: false),
            reason: reason,
          );
          expect(treeDifference(line.tree!, game.tree), isNull, reason: reason);
          final name = tagValue(game.tags, 'ChapterName')?.trim();
          expect(
            sectionOf(line),
            name == null || name.isEmpty ? null : name,
            reason: reason,
          );
          // Each case's id is its own seed, so two games share one only
          // when the list holds one case twice, and then the second is
          // trained under an id worked out from its place.
          final id = tagValue(game.tags, 'LineID');
          final first = games.indexWhere(
            (other) => tagValue(other.tags, 'LineID') == id,
          );
          if (id != null && first == index) {
            expect(line.lineId, id, reason: reason);
          }
        }
      },
      runs: 100,
    );
  });

  group('a course edited through the workspace\'s splice', () {
    forAll(
      'an edit to one chapter leaves every game outside it byte for byte',
      _courseEdits,
      _expectOthersKept,
      runs: 150,
    );
  });

  group('hostile but legal text', () {
    test('the fifty-deep game nests fifty deep', () {
      final text = _hostile['variations nested fifty deep']!;
      expect(_deepest(readGame(text).tree!), 50);
    });
    for (final MapEntry(key: name, value: text) in _hostile.entries) {
      test(name, () => _expectSurvives(text));
    }
  });
}

// ---------------------------------------------------------------------------
// Laws 1 and 2 over one game's text
// ---------------------------------------------------------------------------

/// Asserts laws 1 and 2 of [text], a game reading takes whole: written from
/// what reading gave, it reads back as the same game, and writing that
/// again gives the same bytes. The rewrite gate takes it too.
void expectSameGameWritten(String text, String game) {
  final read = readGame(text);
  expect(read.issues, isEmpty, reason: game);
  final once = written(read);
  final back = readGame(once);
  final reason = '$game\nread from\n$text\nwritten as\n$once';
  expect(back.issues, isEmpty, reason: reason);
  expect(_tags(back.tags), _tags(read.tags), reason: reason);
  expect(treeDifference(back.tree!, read.tree!), isNull, reason: reason);
  expect(_tokens(back.tree!), _tokens(read.tree!), reason: reason);
  expect(back.terminator, read.terminator, reason: reason);
  expect(back.separator, read.separator, reason: reason);
  expect(written(back), once, reason: reason);
  expect(refusal(text), isNull, reason: reason);
}

/// Asserts that [line], written again, is still the game a saved reading
/// place names.
void expectKeyKept(ChapterLine line, String game) {
  final rewrite = rewritten(line, line.tree!);
  if (rewrite is! LineRewritten) fail('$game refused: $rewrite');
  expect(readingGameKey(rewrite.line), readingGameKey(line), reason: game);
}

/// Every header line as the file has it — key, value, the text written and
/// what followed it — in order.
List<String> _tags(List<PgnHeader> tags, {bool trailers = true}) => [
  for (final tag in tags)
    [
      if (tag case PgnTag(:final key, :final value)) '$key=$value',
      tag.text,
      if (trailers) jsonEncode(tag.trailer),
    ].join('|'),
];

final _token = RegExp(r'\[%[^\]]*\]');

/// Every `[%…]` token of [tree]'s comments, in the order the file has them.
List<String> _tokens(GameTree tree) {
  final found = <String>[];
  void scan(String? comment) {
    if (comment == null) return;
    found.addAll(_token.allMatches(comment).map((m) => m[0]!));
  }

  scan(tree.rootComment);
  void walk(List<MoveNode> nodes) {
    for (final node in nodes) {
      scan(node.startingComment);
      scan(node.comment);
      walk(node.children);
    }
  }

  walk(tree.children);
  return found;
}

/// How many variations deep [tree] nests at its deepest.
int _deepest(GameTree tree) {
  var deepest = 0;
  final pending = [
    for (final (index, child) in tree.children.indexed)
      (child, index == 0 ? 0 : 1),
  ];
  while (pending.isNotEmpty) {
    final (node, depth) = pending.removeLast();
    if (depth > deepest) deepest = depth;
    for (final (index, child) in node.children.indexed) {
      pending.add((child, index == 0 ? depth : depth + 1));
    }
  }
  return deepest;
}

// ---------------------------------------------------------------------------
// Law 3: a course edited through the splice
// ---------------------------------------------------------------------------

/// The fixtures a course is imported from, beside generated chapters.
const _courseParts = [
  'chessable_course.pgn',
  'lichess_study.pgn',
  'chessbase.pgn',
  'old_app_chapter.pgn',
  'dialects.pgn',
];

/// A course of two to four parts, fixtures or generated chapters, and one
/// edit of one game to one of its chapters: a note, a glyph or a move.
final Generator<EditCase> _courseEdits = Generator(
  (r) => EditCase(
    CourseFile([
      for (var i = r.between(2, 4); i > 0; i--)
        r.chance(50)
            ? LiteralFile(
                File(
                  p.join(_pgnFolder, r.pick(_courseParts)),
                ).readAsStringSync(),
              )
            : GeneratedFile(editableChapters(maxGames: 3).sample(r)),
    ]),
    focus: Focus.section,
    pick: r.nextInt(1 << 20),
    edits: [
      sampleEdit(
        r,
        kinds: const [EditKind.comment, EditKind.glyph, EditKind.addMove],
      ),
    ],
  ),
  shrinker: shrunkCase,
);

/// The edit of [c] landed as the workspace lands it: every game of the file
/// outside the chapter edited keeps its bytes and its place, every game the
/// edit did not write keeps its bytes, and every game keeps its chapter
/// name and line id.
void _expectOthersKept(EditCase c) {
  final step = runEdits(c).single;
  final outcome = step.outcome;
  if (outcome is! EditLanded) return;
  final before = step.shown.file;
  final after = wholeFile(outcome.landed.text);
  final games = outcome.games;
  final trainedIds = trainedIdsOf(before);
  final edited =
      (step.shown.view?.places ??
              [for (var i = 0; i < before.lines.length; i++) i])
          .toSet();
  final reason = '${step.spec}\nbefore:\n${step.before}\nafter:\n${step.after}';
  // A first game written into a file of none is set off from its heading
  // by a blank line; the heading itself is kept.
  if (before.lines.isNotEmpty) {
    expect(after.preamble, before.preamble, reason: reason);
  } else {
    expect(after.preamble.trimRight(), before.preamble.trimRight());
  }
  expect(games.keepsPlaces, isTrue, reason: reason);
  expect(
    games.rewritten.difference(edited),
    isEmpty,
    reason: 'a game of another chapter was written\n$reason',
  );
  for (final (index, line) in before.lines.indexed) {
    final now = after.lines[index];
    final at = 'game $index\n$reason';
    if (!games.rewritten.contains(index)) {
      expect(now.text, line.text, reason: at);
    }
    expect(
      tagValue(now.tags, 'ChapterName'),
      tagValue(line.tags, 'ChapterName'),
      reason: at,
    );
    // A game the edit wrote may gain a `[LineID]` pinning the id it was
    // trained under, which its new moves would otherwise change.
    final id = tagValue(line.tags, 'LineID');
    final pinned = games.rewritten.contains(index) && id == null;
    expect(
      tagValue(now.tags, 'LineID'),
      pinned ? anyOf(isNull, trainedIds[index]) : id,
      reason: at,
    );
    if (line.isWhole) {
      expect(now.isWhole, isTrue, reason: at);
      expect(_tokensOutside(now, step), _tokensOutside(line, step), reason: at);
    }
  }
}

/// The `[%…]` tokens of [line] outside the move [step] wrote on, which no
/// edit of one move may change. A note edit keeps the tokens of its own
/// move too, which `edit_laws_test` checks.
List<String> _tokensOutside(ChapterLine line, EditStep step) {
  final sans = step.sans;
  final tree = line.tree!;
  if (sans == null) return _tokens(tree);
  final path = pathOfSans(tree, sans);
  if (path == null) return _tokens(tree);
  final node = tree.nodeAt(path);
  if (node == null) return _tokens(tree);
  final without = node.copyWith(comment: '');
  return _tokens(replaceNode(tree, path, without));
}

/// [tree] with the node at [path] replaced by [node].
GameTree replaceNode(GameTree tree, NodePath path, MoveNode node) {
  List<MoveNode> under(List<MoveNode> nodes, List<int> rest) => [
    for (final (index, child) in nodes.indexed)
      index != rest.first
          ? child
          : rest.length == 1
          ? node
          : child.copyWith(children: under(child.children, rest.sublist(1))),
  ];
  if (path.indexes.isEmpty) return tree;
  return GameTree(
    rootFen: tree.rootFen,
    rootComment: tree.rootComment,
    children: under(tree.children, path.indexes),
  );
}

// ---------------------------------------------------------------------------
// Law 4: hostile but legal text
// ---------------------------------------------------------------------------

/// Text a reader must survive: each one is legal PGN or a file the app
/// meets, and each must neither throw nor hang.
final Map<String, String> _hostile = {
  'an empty file': '',
  'only whitespace': ' \n\r\n\t\n',
  'an empty game': '[Event "A"]\n\n',
  'only tags': '[Event "A"]\n[Site "B"]\n[Result "*"]\n',
  'only tags, no newline at the end': '[Event "A"]\n[Result "*"]',
  'two empty games': '[Event "A"]\n\n*\n\n[Event "B"]\n\n*\n',
  'an unterminated brace': '[Event "A"]\n\n1. e4 {never closed e5 2. Nf3 *\n',
  'an unterminated brace before the next game':
      '[Event "A"]\n\n1. e4 {open\n\n[Event "B"]\n\n1. d4 *\n',
  'an unterminated variation': '[Event "A"]\n\n1. e4 (1. d4 d5 2. c4 *\n',
  'variations nested fifty deep': _nestedFifty(),
  'variations nested five hundred deep, each a first move again': [
    '[Event "Deep"]\n\n1. e4 ',
    for (var i = 0; i < 500; i++) '(1. ${_firstMoves[i % _firstMoves.length]} ',
    for (var i = 0; i < 500; i++) ')',
    ' e5 *\n',
  ].join(),
  'CRLF throughout':
      '[Event "A"]\r\n[Result "*"]\r\n\r\n1. e4 {a\r\nnote} e5 *\r\n',
  'mixed line endings':
      '[Event "A"]\r\n[Site "B"]\n[Result "*"]\r\n\n1. e4\r\ne5\n2. Nf3 *\r\n'
      '\n[Event "C"]\n\r\n1. d4 *\n',
  'a lone carriage return between moves': '[Event "A"]\n\n1. e4\re5 *\n',
  'a byte-order mark': '\uFEFF[Event "A"]\n\n1. e4 *\n',
  'a byte-order mark before a preamble':
      '\uFEFF// Course\n\n[Event "A"]\n\n1. e4 *\n',
  'two byte-order marks': '\uFEFF\uFEFF[Event "A"]\n\n1. e4 *\n',
  'non-ASCII names':
      '[Event "Чемпионат"]\n[White "Böhm, Ö"]\n[Black "王皓"]\n\n'
      '1. e4 {½ → ∞ ♞ 👍} *\n',
  'escaped quotes and backslashes in tags':
      '[Event "He said \\"go\\" \\\\ done"]\n[Site "C:\\\\x"]\n\n1. e4 *\n',
  'an unescaped backslash in a tag': '[Event "a\\b"]\n\n1. e4 *\n',
  'a tag value never closed': '[Event "open\n\n1. e4 *\n',
  'a very long comment': '[Event "A"]\n\n1. e4 {${'word ' * 40000}} e5 *\n',
  'a very long tag value': '[Event "${'x' * 100000}"]\n\n1. e4 *\n',
  'no Result tag and no marker': '[Event "A"]\n\n1. e4 e5\n',
  'no Result tag, a marker': '[Event "A"]\n\n1. e4 e5 1-0\n',
  'no tags at all': '1. e4 e5 *\n',
  'a marker and nothing else': '*',
  'a null move only': '[Event "A"]\n\n{Introduction} 1. -- *\n',
  'every NAG':
      '[Event "A"]\n\n1. e4 ${[for (var i = 0; i < 256; i++) '\$$i'].join(' ')} *\n',
  'machine tokens of every kind':
      '[Event "A"]\n\n1. e4 {[%eval 0.17,22] [%clk 0:05:00] '
      '[%pv e7e5 g1f3] [%cal Ge2e4,Rd7d5] [%csl Gd4,Re5] [%emt 0:00:03]} *\n',
  'a semicolon comment at the end of the file': '[Event "A"]\n\n1. e4 ; done',
  'a percent escape line': '[Event "A"]\n% kept\n\n1. e4 *\n',
  'a percent sign starting a line inside a comment':
      '[Event "A"]\n\n1. e4 {a note\n% still the note} e5 *\n',
  'a header quoted inside a comment':
      '[Event "A"]\n\n1. e4 {\n[Event "quoted"]\n} e5 *\n',
  'a closing bracket inside a tag value': '[Event "a]b"]\n\n1. e4 *\n',
  'two tags on one line': '[Event "A"] [Site "B"]\n\n1. e4 *\n',
  'a tab between key and value': '[Event\t"A"]\n\n1. e4 *\n',
  'tag keys nobody defines':
      '[Event "A"]\n[eco-code "B"]\n[1st "C"]\n\n1. e4 *\n',
  'a machine token never closed': '[Event "A"]\n\n1. e4 {[%eval 0.3} e5 *\n',
  'a NAG out of range': '[Event "A"]\n\n1. e4 \$0 \$256 \$99999 *\n',
  'text after the marker': '[Event "A"]\n\n1. e4 * and then words\n',
};

const _firstMoves = ['d4', 'c4', 'Nf3', 'g3', 'b3', 'f4', 'Nc3', 'e3'];

/// A game whose variations nest fifty deep, built through the model.
String _nestedFifty() {
  final tree = GameTree(
    rootFen: Fen.initial,
    children: nestedVariations(Rand(50), Fen.initial, 50),
  );
  return '[Event "Fifty"]\n\n${writeGameText(const [], tree, terminator: '*', separator: '')}\n';
}

/// Asserts that [text] reads and writes without throwing and in good time,
/// comes back byte for byte, and that each game reading took whole keeps
/// laws 1 and 2. A game it did not take whole is set aside with its bytes,
/// which is what failing open means here.
void _expectSurvives(String text) {
  final clock = Stopwatch()..start();
  final chapter = parseChapter(name: 'Hostile', text: text);
  expect(writeChapter(chapter), text);
  for (final (index, line) in chapter.lines.indexed) {
    final read = readGame(line.text);
    if (!line.isWhole) {
      expect(read.rewritable, isFalse, reason: 'game $index');
      continue;
    }
    expectSameGameWritten(line.text, 'game $index');
  }
  expect(clock.elapsed, lessThan(const Duration(seconds: 5)));
}

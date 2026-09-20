import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/pgn/chapter_edits.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/chess/pgn/pgn_reader.dart';
import 'package:chess_auto_prep/v2/chess/pgn/rewrite_gate.dart';
import 'package:flutter_test/flutter_test.dart';

/// One game, a comment away from being written again.
GameTree treeWithComment(String game, String comment) {
  final tree = readGame(game).tree!;
  return GameTree(
    rootFen: tree.rootFen,
    rootComment: tree.rootComment,
    children: [
      tree.children.first.copyWith(comment: comment),
      ...tree.children.skip(1),
    ],
  );
}

const _oneGame =
    '// Color: White\n'
    '\n'
    '[Event "A"]\n'
    '[Result "*"]\n'
    '[LineID "line_abc"]\n'
    '\n'
    '1. d4 d5 *\n';

void main() {
  test('a game the writer can say comes back with its text', () {
    final read = readGame('[Event "A"]\n\n1. e4 e5 *');
    final rewrite = safeGameText(
      tags: read.tags,
      tree: treeWithComment('1. e4 e5 *', 'King pawn'),
      terminator: read.terminator,
      separator: read.separator,
    );
    expect(rewrite, isA<RewriteReady>());
    expect(
      (rewrite as RewriteReady).text,
      '[Event "A"]\n\n1. e4 {King pawn} e5 *',
    );
  });

  test('a comment holding a closing brace is refused, not stripped', () {
    final read = readGame('[Event "A"]\n\n1. e4 e5 *');
    final rewrite = safeGameText(
      tags: read.tags,
      tree: treeWithComment('1. e4 e5 *', 'careful } here'),
      terminator: read.terminator,
      separator: read.separator,
    );
    expect(rewrite, isA<RewriteRefused>());
  });

  test('a chapter rewrite that the gate refuses keeps the game it had', () {
    final chapter = parseChapter(name: 'A', text: _oneGame);
    final line = chapter.lines.single;
    final kept = rewritten(line, treeWithComment('1. d4 d5 *', 'a } brace'));
    expect(identical(kept, line), isTrue);
    expect(writeChapter(withLines(chapter, [kept])), _oneGame);
  });

  test('a chapter rewrite the gate allows keeps every tag it had', () {
    final chapter = parseChapter(name: 'A', text: _oneGame);
    final line = rewritten(
      chapter.lines.single,
      treeWithComment('1. d4 d5 *', 'Main line'),
    );
    expect(line.text, contains('[LineID "line_abc"]'));
    expect(line.text, endsWith('1. d4 {Main line} d5 *'));
    expect(writeChapter(withLines(chapter, [line])), contains('{Main line}'));
  });

  group('an edit whose words a PGN file cannot hold', () {
    final chapter = parseChapter(name: 'A', text: _oneGame);

    test('is refused before any game is touched', () {
      final result = setComment(
        chapter,
        at: NodePath.of([0]),
        text: 'careful } here',
      );
      expect(result, isA<CommentUnwritable>());
      expect(
        (result as CommentUnwritable).reason,
        'a comment cannot hold a closing brace',
      );
    });

    test('leaves the chapter alone', () {
      setComment(chapter, at: NodePath.of([0]), text: 'a } b');
      expect(writeChapter(chapter), _oneGame);
    });

    test('is refused for the chapter introduction too', () {
      expect(
        setComment(chapter, at: const NodePath.root(), text: 'a } b'),
        isA<CommentUnwritable>(),
      );
    });
  });

  test('clearing a comment is not refused', () {
    final chapter = parseChapter(name: 'A', text: _oneGame);
    expect(
      setComment(chapter, at: NodePath.of([0]), text: null),
      isA<CommentWritten>(),
    );
  });
}

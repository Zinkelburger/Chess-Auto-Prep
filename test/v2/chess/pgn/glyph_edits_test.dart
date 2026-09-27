import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/pgn/comment_edits.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

void main() {
  final at = NodePath.of([0]);

  test('one of the six goes on the move, in place of another', () async {
    final chapter = await readChapter(name: 'Main', text: blackChapter);
    final marked = setGlyph(chapter, at: at, nag: 1) as CommentWritten;
    expect(marked.chapter.tree.nodeAt(at)?.nags, [1]);
    expect(writeChapter(marked.chapter), contains(r'c5 $1'));
    final changed = setGlyph(marked.chapter, at: at, nag: 6) as CommentWritten;
    expect(changed.chapter.tree.nodeAt(at)?.nags, [6]);
    final cleared = setGlyph(changed.chapter, at: at) as CommentWritten;
    expect(cleared.chapter.tree.nodeAt(at)?.nags, isEmpty);
    expect(writeChapter(cleared.chapter), blackChapter);
  });

  test('other annotation numbers stay', () async {
    final chapter = await readChapter(
      name: 'Main',
      text: '// Color: White\n\n[Event "A"]\n\n1. e4 \$14 *\n',
    );
    final marked = setGlyph(chapter, at: at, nag: 2) as CommentWritten;
    expect(marked.chapter.tree.nodeAt(at)?.nags, [2, 14]);
  });

  test('the same glyph again changes nothing', () async {
    final chapter = await readChapter(name: 'Main', text: blackChapter);
    final marked = setGlyph(chapter, at: at, nag: 1) as CommentWritten;
    final again = setGlyph(marked.chapter, at: at, nag: 1) as CommentWritten;
    expect(identical(again.chapter, marked.chapter), isTrue);
  });

  test('the start position takes no glyph', () async {
    final chapter = await readChapter(name: 'Main', text: blackChapter);
    final result = setGlyph(chapter, at: const NodePath.root(), nag: 1);
    expect(identical((result as CommentWritten).chapter, chapter), isTrue);
  });
}

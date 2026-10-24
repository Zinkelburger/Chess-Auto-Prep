import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/pgn/chapter_edit.dart';
import 'package:chess_auto_prep/chess/pgn/game_text.dart';
import 'package:chess_auto_prep/chess/pgn/study_cleanup.dart';
import 'package:chess_auto_prep/chess/pgn/study_lichess.dart';
import 'package:flutter_test/flutter_test.dart';

/// The game the plane scenario ends with: typed in from a scoresheet,
/// annotated by hand, reviewed by the engine.
const _study = '''[Event "Plane games: Chapter 1"]
[StudyName "Plane games"]
[ChapterName "Chapter 1"]
[Orientation "white"]
[LineID "line_ZTR8MA"]
[White "Morphy, Paul"]
[Black "Duke Karl / Count Isouard"]
[Date "1858.11.02"]
[WhiteElo "?"]
[Result "1-0"]

{[%eval +0.30] [%cap_review_eval]} 1. e4 e5 2. Nf3 d6 3. d4 Bg4 4. dxe5 Bxf3 \$2 {Mistake. Nd7 was best. [%eval +1.87] [%cap_review_eval] [%cap_review_nag 2]} (4... Nd7 {[%cap_review_line 8]} 5. exd6) 5. Qxf3 dxe5 6. Bc4 Nf6 7. Qb3 Qe7 8. Nc3 c6 9. Bg5 b5 \$6 {Too slow. [%csl Gd7] [%cal Gb5e8]} 10. Nxb5 1-0

[Event "Paris Opera, 1858"]
[StudyName "Plane games"]
[ChapterName "Rook ending"]
[Orientation "black"]
[FEN "8/8/4k3/8/8/4K3/4P3/8 w - - 0 1"]
[SetUp "1"]
[ChapterURL "https://lichess.org/study/abcd1234/efgh5678"]
[Result "*"]

1. Kd3 *
''';

void main() {
  final chapter = parseChapter(name: 'Plane games', text: _study, game: 0);

  test('a chapter goes with the tags Lichess keeps and every annotation', () {
    final pgn = lichessChapterPgn(chapter.lines.first, index: 0)!;
    expect(pgn, contains('[White "Morphy, Paul"]'));
    expect(pgn, contains('[Black "Duke Karl / Count Isouard"]'));
    expect(pgn, contains('[Date "1858.11.02"]'));
    expect(pgn, contains('[Result "1-0"]'));
    // The study's own Event, the app's tags and empty values stay here.
    expect(pgn, isNot(contains('Event')));
    expect(pgn, isNot(contains('LineID')));
    expect(pgn, isNot(contains('StudyName')));
    expect(pgn, isNot(contains('WhiteElo')));
    // Moves, glyphs, words and shapes go as they are.
    expect(pgn, contains(r'b5 $6 {Too slow. [%csl Gd7] [%cal Gb5e8]}'));
    expect(pgn, contains('(4... Nd7'));
    expect(pgn.trimRight(), endsWith('10. Nxb5 1-0'));
  });

  test('an event the player typed goes; a set-up position goes with it', () {
    final pgn = lichessChapterPgn(chapter.lines.last, index: 1)!;
    expect(pgn, contains('[Event "Paris Opera, 1858"]'));
    expect(pgn, contains('[FEN "8/8/4k3/8/8/4K3/4P3/8 w - - 0 1"]'));
    expect(pgn, contains('[SetUp "1"]'));
    expect(pgn, isNot(contains('ChapterURL')));
    expect(lichessTagsOf(chapter.lines.last, index: 1), {
      'Result': '*',
      'Event': 'Paris Opera, 1858',
    });
  });

  test('where Lichess keeps the chapters is written as one edit', () {
    final edit =
        withStudyTag(chapter, chapterUrlTag, {
              0: 'https://lichess.org/study/wxyz9876/aaaa1111',
              1: 'https://lichess.org/study/wxyz9876/bbbb2222',
            })
            as ChapterEdited;
    expect(edit.games.rewritten, {0, 1});
    final lines = edit.chapter.lines;
    expect(
      tagValue(lines.first.tags, chapterUrlTag),
      'https://lichess.org/study/wxyz9876/aaaa1111',
    );
    expect(
      tagValue(lines.last.tags, chapterUrlTag),
      'https://lichess.org/study/wxyz9876/bbbb2222',
    );
    expect(
      lines.last.tags.whereType<PgnTag>().where((t) => t.key == chapterUrlTag),
      hasLength(1),
      reason: 'replaced in place, not added twice',
    );
    expect(lines.first.tree!.children.first.san, 'e4');
    expect(
      withStudyTag(edit.chapter, chapterUrlTag, {
        0: 'https://lichess.org/study/wxyz9876/aaaa1111',
      }),
      isA<ChapterUnchanged>(),
    );
  });
}

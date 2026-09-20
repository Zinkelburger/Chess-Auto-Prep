/// Chapter files in the on-disk format, modelled on what the old app writes.
///
/// Every one of them must survive `writeChapter(parseChapter(x)) == x`, so
/// they carry the parts a naive round trip loses: unmodelled tags, machine
/// tokens in comments, a variation inside a game and a game that starts
/// somewhere else.
library;

/// A chapter rooted after 1. e4: the app's `//` metadata, then two lines
/// from that position, the second adding a variation, then a game from
/// another root that readers skip.
const blackChapter = '''
// Color: Black
// Created on 2026-08-20 00:46:52

[Event "Test: Repertoire for Black"]
[Result "*"]
[FEN "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1"]
[SetUp "1"]

1... c5 {The Sicilian [%eval 0.30]} 2. Nf3 d6 (2... Nc6 {Open games} 3. d4) 3. d4 cxd4 *

[Event "Test: Repertoire for Black"]
[Result "*"]
[FEN "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1"]
[SetUp "1"]

1... c5 2. Nc3 {Closed} Nc6 *

[Event "Elsewhere"]
[Result "*"]

1. d4 d5 *
''';

/// A White chapter from the initial position with everything a generated
/// chapter carries: an introduction, the full preamble, SM-2 review state,
/// `CumProb`, `Annotator`, line ids, a NAG, a variation inside a game and
/// engine and clock tokens in the comments.
const whiteChapter = '''
// Queen's Gambit
// Color: White
// Chapter: 1) Exchange
// Created on 2026-09-18 21:04:11
// Root: 1. d4 d5 2. c4

[Event "Queen's Gambit: Repertoire for White"]
[White "Me"]
[Black "Training"]
[Result "*"]
[LineID "line_MS4gZDQgZDUgMi4gYzQ"]
[LastReview "2026-09-10T08:12:00.000Z"]
[Difficulty "2.50"]
[Interval "6.00"]
[DueDate "2026-09-16T08:12:00.000Z"]
[PassCount "3"]
[FailCount "1"]
[CumProb "0.42"]
[Annotator "Chess Auto Prep"]

{Our repertoire against 1... d5.} 1. d4 d5 2. c4 e6 {[%eval 0.21] [%clk 0:29:41]} 3. cxd5 exd5 (3... Nf6 \$6 {Rarely played.} 4. dxe6) 4. Nc3 *

[Event "Queen's Gambit: Repertoire for White"]
[White "Me"]
[Black "Training"]
[Result "*"]
[LineID "line_MS4gZDQgZDUgMi4gYzUx"]
[CumProb "0.31"]

1. d4 d5 2. c4 c6 {The Slav [%eval 0.18]} 3. Nf3 *

[Event "Queen's Gambit: Repertoire for White"]
[White "Me"]
[Black "Training"]
[Result "*"]
[LineID "line_MS4gZDQgZDUgMi4gYzYy"]

1. d4 Nf6 *
''';

/// A chapter with nothing in it yet: the metadata a newly created file
/// carries and no game at all.
const emptyChapter = '''
// Sidelines
// Color: White
// Created on 2026-09-19 09:30:00
''';

/// Every fixture, for the checks that must hold on all of them.
const chapterFixtures = <String, String>{
  'blackChapter': blackChapter,
  'whiteChapter': whiteChapter,
  'emptyChapter': emptyChapter,
};

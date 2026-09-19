/// A small chapter in the on-disk format: the app's `//` metadata line, then
/// two lines from the same position, the second adding a variation.
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

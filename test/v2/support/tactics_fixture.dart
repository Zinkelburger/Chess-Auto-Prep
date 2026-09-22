import 'package:chess_auto_prep/v2/storage/chapter_files.dart';

/// Where the tactics set is in the scripted store.
final tacticsRef = ChapterRef.at('/Documents/tactics_sets/Default.pgn');

/// The day the tests run on: the set's dates are a few days before it.
final tacticsToday = DateTime(2026, 9, 22, 10);

/// A set in the old app's shape: the analyzed-games line, then one game per
/// puzzle.
///
/// 0. A blunder, White to mate in one: `4. Qxf7#`.
/// 1. A mistake, Black to find `1... e5`, White replies `2. Nf3`, Black
///    finds `2... Nc6` — two moves to find.
/// 2. An inaccuracy, which the default filter leaves out.
/// 3. A custom puzzle with no date or mistake type.
/// 4. A blunder from a month ago, which the fortnight window leaves out.
const tacticsSet = '''
; ChessAutoPrep-Analyzed-v1: WyJsaWNoZXNzX2FiYyJd
[Event "Default #1"]
[White "Me"]
[Black "Rival"]
[Date "2026.09.20"]
[Result "*"]
[FEN "r1bqkb1r/pppp1ppp/2n2n2/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w KQkq - 4 4"]
[SetUp "1"]
[GameId "lichess_abc"]
[UserMove "Qe2"]
[MistakeType "??"]
[OpponentBestResponse "Nd4"]
[FlawTags "opening hasty"]

{Qe2 +9.9 → +0.3, Qxf7# +9.9} 4. Qxf7# *

[Event "Default #2"]
[White "Other"]
[Black "Me"]
[Date "2026.09.21"]
[Result "*"]
[FEN "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1"]
[SetUp "1"]
[GameId "lichess_def"]
[UserMove "f6"]
[MistakeType "?"]
[OpponentBestResponse "d4"]

{f6 +0.3 → -1.1, e5 +0.3} 1... e5 2. Nf3 Nc6 *

[Event "Default #3"]
[White "Me"]
[Black "Rival"]
[Date "2026.09.20"]
[Result "*"]
[FEN "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"]
[SetUp "1"]
[UserMove "a3"]
[MistakeType "?!"]

1. e4 *

[Event "Default #4"]
[Result "*"]
[FEN "rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq - 0 1"]
[SetUp "1"]

1... d5 *

[Event "Default #5"]
[White "Me"]
[Black "Old"]
[Date "2026.08.01"]
[Result "*"]
[FEN "rnbqkbnr/pppppppp/8/8/8/5N2/PPPPPPPP/RNBQKB1R b KQkq - 1 1"]
[SetUp "1"]
[UserMove "h5"]
[MistakeType "??"]

1... d5 *
''';

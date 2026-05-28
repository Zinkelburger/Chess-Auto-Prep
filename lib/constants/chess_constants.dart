/// Standard chess positions and shared FEN constants.
library;

/// Standard starting position FEN (full 6-field).
const String kStandardStartFen =
    'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

/// Standard starting position FEN without move counters (4-field, for
/// comparison after [normalizeFen]).
const String kStandardStartFenShort =
    'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -';

/// Default values and valid ranges for engine / analysis settings.
///
/// Used by [EngineSettings] for field initializers, [loadFromPrefs] fallbacks,
/// and [resetToDefaults] — eliminating triple duplication of literal values.
library;

// ── Stockfish ────────────────────────────────────────────────────────────────

const int kDefaultDepth = 15;
const int kMinDepth = 1;
const int kMaxDepth = 99;

const int kDefaultMultiPv = 3;
const int kMinMultiPv = 1;
const int kMaxMultiPv = 10;

const int kDefaultInlineThreads = 1;

/// Start conservatively; users can opt into more CPU in engine settings.
const int kDefaultWorkers = 1;
const int kDefaultGenerationThreads = 1;

const int kDefaultMaxAnalysisMoves = 8;
const int kMinMaxAnalysisMoves = 3;
const int kMaxMaxAnalysisMoves = 20;

/// How many text rows each engine row gives its principal variation before
/// the continuation is ellipsised. 1 restores the old single-line behavior.
const int kDefaultPvRows = 2;
const int kMinPvRows = 1;
const int kMaxPvRows = 4;

// ── Maia / candidates ────────────────────────────────────────────────────────

const int kDefaultMaiaElo = 2200;
const int kMinMaiaElo = 600;
const int kMaxMaiaElo = 2400;

const int kDefaultStockfishTopN = 3;
const int kMinStockfishTopN = 1;
const int kMaxStockfishTopN = 10;

// ── Explorer ─────────────────────────────────────────────────────────────────

const String kDefaultExplorerDatabase = 'lichess';
const String kDefaultExplorerSpeeds = 'blitz,rapid,classical';
const String kDefaultExplorerRatings = '1800,2000,2200,2500';

// ── UI defaults ──────────────────────────────────────────────────────────────

const bool kDefaultShowStockfish = true;
const bool kDefaultShowMaia = true;
const bool kDefaultShowProbability = true;
const bool kDefaultShowEngineDock = true;
const bool kDefaultShowExpectimaxDock = true;

// ── Trap classification thresholds (centipawn loss vs best move) ─────────────

const int kTrapBlunderThreshold = 200;
const int kTrapMistakeThreshold = 100;
const int kTrapInaccuracyThreshold = 50;
const int kTrapAcceptableThreshold = 20;

// ── Repertoire tree generation (Phase 1 build) ───────────────────────────────

const int kDefaultGenerationEvalDepth = 14;

// ── Opening tree build ───────────────────────────────────────────────────────

const int kOpeningTreeMaxDepth = 50;

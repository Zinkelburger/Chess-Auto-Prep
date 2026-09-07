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

/// CPU cores Stockfish may use. Start conservatively; the user raises it in
/// App settings. One number covers both uses: the board engine runs them as
/// threads in one process, bulk review runs that many single-thread
/// processes.
const int kDefaultCores = 1;
const int kDefaultGenerationThreads = 1;

/// RAM per Stockfish process for its search table (UCI Hash), in MB. 128 MB
/// is comfortable up to about depth 25; bulk review runs one process per
/// core, so the total is cores × this.
const int kDefaultHashMb = 128;
const int kMinHashMb = 16;
const int kMaxHashMb = 8192;

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

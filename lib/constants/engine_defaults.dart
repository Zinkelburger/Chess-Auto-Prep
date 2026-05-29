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

const int kDefaultMaxAnalysisMoves = 8;
const int kMinMaxAnalysisMoves = 3;
const int kMaxMaxAnalysisMoves = 20;

// ── Maia / candidates ────────────────────────────────────────────────────────

const int kDefaultMaiaElo = 2200;
const int kMinMaiaElo = 600;
const int kMaxMaiaElo = 2400;

const int kDefaultStockfishTopN = 3;
const int kMinStockfishTopN = 1;
const int kMaxStockfishTopN = 10;

const int kDefaultOnTheFlyMaxDepth = 5;
const int kMinOnTheFlyMaxDepth = 1;
const int kMaxOnTheFlyMaxDepth = 12;

// ── Expectimax tree build ────────────────────────────────────────────────────

const int kDefaultExpOurMultipv = 4;
const int kMinExpOurMultipv = 1;
const int kMaxExpOurMultipv = 8;

const int kDefaultExpOppMaxChildren = 4;
const int kMinExpOppMaxChildren = 1;
const int kMaxExpOppMaxChildren = 12;

const double kDefaultExpOppMassTarget = 0.80;
const double kMinExpOppMassTarget = 0.5;
const double kMaxExpOppMassTarget = 1.0;

const double kDefaultExpMinProb = 0.02;
const double kMinExpMinProb = 0.005;
const double kMaxExpMinProb = 0.2;

const int kDefaultExpMaxEvalLoss = 80;
const int kMinExpMaxEvalLoss = 20;
const int kMaxExpMaxEvalLoss = 300;

const int kDefaultExpEvalDepth = 12;
const int kMinExpEvalDepth = 6;
const int kMaxExpEvalDepth = 20;

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

// ── Infrastructure ───────────────────────────────────────────────────────────

/// Port for the browser-extension localhost HTTP/WebSocket server.
const int kBrowserExtensionPort = 9812;

// ── Trap classification thresholds (centipawn loss vs best move) ─────────────

const int kTrapBlunderThreshold = 200;
const int kTrapMistakeThreshold = 100;
const int kTrapInaccuracyThreshold = 50;
const int kTrapAcceptableThreshold = 20;

// ── Repertoire tree generation (Phase 1 build) ───────────────────────────────

const int kDefaultGenerationEvalDepth = 14;

// ── Opening tree build ───────────────────────────────────────────────────────

const int kOpeningTreeMaxDepth = 50;

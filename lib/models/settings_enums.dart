/// Typed enums for settings that were previously stringly-typed.
library;

/// How the app predicts opponent move probabilities.
enum OpponentProbabilityMode {
  maia,
  lichess,
  maiaLichessFallback;

  String get label => switch (this) {
    maia => 'Maia neural net',
    lichess => 'Lichess database frequencies',
    maiaLichessFallback => 'Maia + DB fallback',
  };

  /// Legacy string key used in SharedPreferences.
  String get storageKey => switch (this) {
    maia => 'maia',
    lichess => 'lichess',
    maiaLichessFallback => 'maia_lichess_fallback',
  };

  static OpponentProbabilityMode fromStorageKey(String key) => switch (key) {
    'maia' => maia,
    'lichess' => lichess,
    _ => maiaLichessFallback,
  };
}

/// Source for candidate move generation (our moves or opponent moves).
enum CandidateSource {
  maia,
  stockfish;

  String get label => switch (this) {
    maia => 'Maia',
    stockfish => 'Stockfish',
  };

  String get storageKey => name;

  static CandidateSource fromStorageKey(String key) => switch (key) {
    'stockfish' => stockfish,
    _ => maia,
  };
}

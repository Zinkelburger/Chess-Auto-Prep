/// Remote modes use their database first and Stockfish for missing positions.
/// The source is part of a saved search's identity.
enum EvaluationSource {
  stockfish('Stockfish'),
  chessDb('ChessDB + Stockfish'),
  lichess('Lichess cloud + Stockfish');

  const EvaluationSource(this.label);
  final String label;
}

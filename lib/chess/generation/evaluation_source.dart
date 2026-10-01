/// Remote modes use their database first and Stockfish for missing positions.
/// The source is part of a saved search's identity.
enum EvaluationSource {
  stockfish('Engine'),
  chessDb('ChessDB'),
  lichess('Lichess cloud');

  const EvaluationSource(this.label);
  final String label;
}

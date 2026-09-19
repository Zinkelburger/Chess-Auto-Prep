/// A position as FEN text.
///
/// Kept as text rather than a dartchess `Position` because text is what PGN
/// headers, caches and databases hold, and a position is cheap to rebuild
/// from it when a board or move generator needs one. Wrapping it stops a FEN
/// from being passed where a SAN, a UCI move or a file path was meant.
extension type const Fen(String value) {
  static const initial = Fen(
    'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
  );

  /// Whose move it is, read from the second FEN field; a malformed FEN reads
  /// as White to move, which is the harmless default for display.
  bool get whiteToMove => _field(1) != 'b';

  /// The full-move number, 1 when the field is missing or not a number.
  int get fullMove => int.tryParse(_field(5) ?? '') ?? 1;

  String? _field(int index) {
    final fields = value.split(' ');
    return index < fields.length ? fields[index] : null;
  }
}

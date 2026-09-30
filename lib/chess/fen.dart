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

  /// The four fields that make a position — pieces, side, castling, en
  /// passant — without the move counters: what two positions reached by
  /// different roads have in common, and what a model or a cache keys on.
  String get position => value.split(' ').take(4).join(' ');

  String? _field(int index) {
    final fields = value.split(' ');
    return index < fields.length ? fields[index] : null;
  }
}

const _fnvOffset = -3750763034362895579; // 0xcbf29ce484222325 as signed
const _fnvPrime = 1099511628211;

/// The key the old app's databases file a position under: 64-bit FNV-1a
/// over [Fen.position], the same sum its importers and the Python tools
/// take, so a row they wrote is found. Two roads to one position share it.
int positionKey(Fen fen) {
  final text = fen.position;
  var hash = _fnvOffset;
  for (var i = 0; i < text.length; i++) {
    hash ^= text.codeUnitAt(i);
    hash *= _fnvPrime;
  }
  return hash;
}

import 'fen.dart';
import 'generation/legal_moves.dart';
import 'pgn/tree_edit.dart' show positionOf;

/// The legal move [text] names in [fen], as UCI (castling king to its
/// destination, `e1g1`), or null while it names none, or more than one.
///
/// [text] is SAN or UCI, as someone types it: `Nf6`, `nf6`, `exd5`, `ed5`,
/// `O-O`, `0-0`, `e8=Q`, `e8q`, `g8f6`. Capture marks, `=`, check signs and
/// annotations are optional. Case only matters where it is the difference:
/// `Bc4` is the bishop, and `bc4` is the pawn when a pawn can take there —
/// when both can, `bc4` names two moves and waits for more.
String? typedMove(Fen fen, String text) {
  final typed = _plain(text);
  final named = _named(fen);
  if (typed.isEmpty || named == null) return null;
  return _match(named, typed);
}

/// [typedMove] while the words are still being typed: null too while they
/// could go on to name another move, so `O-O` waits until `O-O-O` is ruled
/// out. Enter plays what [typedMove] finds.
String? typedMoveSoFar(Fen fen, String text) {
  final typed = _plain(text);
  final named = _named(fen);
  if (typed.isEmpty || named == null) return null;
  final found = _match(named, typed);
  if (found == null) return null;
  final start = typed.toLowerCase();
  final longer = named.any(
    (move) =>
        move.uci != found &&
        move.san.length > typed.length &&
        move.san.toLowerCase().startsWith(start),
  );
  return longer ? null : found;
}

typedef _Named = ({String uci, String san});

/// Every legal move in [fen] as UCI and as plain SAN, or null when [fen] is
/// not a position.
List<_Named>? _named(Fen fen) {
  final position = positionOf(fen);
  if (position == null) return null;
  return [
    for (final move in legalMovesOf(position))
      (uci: move.uci, san: _plain(position.makeSan(move.move).$2)),
  ];
}

String? _match(List<_Named> named, String typed) {
  for (final matches in [
    (String san, String uci) => san == typed,
    (String san, String uci) => uci == typed.toLowerCase(),
    (String san, String uci) => san.toLowerCase() == typed.toLowerCase(),
  ]) {
    final found = [
      for (final move in named)
        if (matches(move.san, move.uci)) move.uci,
    ];
    if (found.length == 1) return found.single;
    if (found.length > 1) return null;
  }
  return null;
}

/// A move as typed with the optional marks gone, castling spelled `O-O`.
String _plain(String text) =>
    text.trim().replaceAll(RegExp(r'[x:=+#!?\s]'), '').replaceAll('0', 'O');

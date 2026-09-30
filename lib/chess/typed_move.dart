import 'package:dartchess/dartchess.dart';

import 'fen.dart';
import 'generation/legal_moves.dart';
import 'pgn/tree_edit.dart' show positionOf;

/// What the words typed so far come to in a position.
sealed class TypedMove {
  const TypedMove();
}

/// The words name one legal move, as UCI (castling king to its destination,
/// `e1g1`), and could not go on to name another: it can be played now.
final class Resolved extends TypedMove {
  const Resolved(this.uci);

  final String uci;
}

/// The words are the start of these legal moves, as UCI, and wait for more:
/// `N` while two knights can move, `O-O` while `O-O-O` is legal too.
final class StillTyping extends TypedMove {
  const StillTyping(this.candidates);

  final List<String> candidates;
}

/// No legal move is written this way, however the words go on.
final class NoMatch extends TypedMove {
  const NoMatch();
}

/// What [text] comes to in [fen], read as someone types a move.
///
/// [text] is SAN or UCI: `Nf6`, `nf6`, `exd5`, `ed5`, `O-O`, `0-0`, `e8=Q`,
/// `e8q`, `g8f6`, `e1h1` (the king taking its rook). Capture marks, `=`,
/// dashes, check signs and annotations are optional, and so is a
/// disambiguation the position does not need: `Ngf3`, `N1f3` and `Ng1f3`
/// are all `Nf3` when only one knight can go there. Case only matters where
/// it is the difference: `Bc4` is the bishop, and `bc4` is the pawn when a
/// pawn can take there.
///
/// A move is [Resolved] as soon as the words name it and no longer words
/// could name another, so `Nf3` plays at once while `O-O` waits for
/// `O-O-O` to be ruled out; Enter plays what [enteredMove] finds.
TypedMove readTypedMove(Fen fen, String text) {
  final moves = _spelled(fen);
  if (moves == null) return const NoMatch();
  final typed = _plain(text);
  final named = _firstReading(_names, moves, typed);
  if (named.length == 1 && !_couldGoOn(moves, typed, named.single)) {
    return Resolved(named.single);
  }
  final candidates = _firstReading(_starts, moves, typed);
  return candidates.isEmpty ? const NoMatch() : StillTyping(candidates);
}

/// The move Enter plays for [text] in [fen]: the one the words name, else
/// the one move they are still the start of, else — when they are the start
/// of one pawn's four promotions only — the queen. Null when that leaves
/// none, or more than one.
String? enteredMove(Fen fen, String text) {
  final moves = _spelled(fen);
  if (moves == null) return null;
  final typed = _plain(text);
  if (typed.isEmpty) return null;
  final named = _firstReading(_names, moves, typed);
  if (named.isNotEmpty) return named.length == 1 ? named.single : null;
  final candidates = _firstReading(_starts, moves, typed);
  if (candidates.length == 1) return candidates.single;
  return _queenOf(candidates);
}

/// A legal move and every way of writing it: [sans] in the case SAN writes
/// them (`Nf3`, `Ngf3`, `N1f3`, `Ng1f3`, `ed5`, `e8Q`, `OO`), [ucis] in
/// lower case (`g1f3`; `e1g1` and `e1h1` for castling). Marks and dashes
/// are left out of both, as [_plain] leaves them out of the words.
typedef _Spelled = ({String uci, List<String> sans, List<String> ucis});

/// Every legal move of [fen], spelled; null when [fen] is not a position.
List<_Spelled>? _spelled(Fen fen) {
  final position = positionOf(fen);
  if (position == null) return null;
  return [
    for (final named in legalMovesOf(position))
      (
        uci: named.uci,
        sans: _sans(position, named.move, castles: named.uci != named.move.uci),
        ucis: {named.uci, named.move.uci}.toList(),
      ),
  ];
}

/// The SAN spellings of [move]. A piece may name the file, the rank or the
/// square it comes from whether or not another could go there too; a pawn
/// names its file when it takes. Castling is `OO` or `OOO`, dashes gone.
List<String> _sans(
  Position position,
  NormalMove move, {
  required bool castles,
}) {
  if (castles) return [move.to > move.from ? 'OO' : 'OOO'];
  final role = position.board.pieceAt(move.from)!.role;
  final to = move.to.name;
  final promotion = move.promotion?.uppercaseLetter ?? '';
  if (role == Role.pawn) {
    final takes = move.from.file != move.to.file;
    return ['${takes ? move.from.file.name : ''}$to$promotion'];
  }
  final piece = role.uppercaseLetter;
  final from = move.from;
  return [
    for (final named in ['', from.file.name, from.rank.name, from.name])
      '$piece$named$to',
  ];
}

/// The three ways words are read, strictest first: as SAN spelled with its
/// capitals, as UCI, as SAN in any case. The first that finds anything is
/// the reading, so `bc4` is the pawn's capture when there is one and the
/// bishop's move only when there is not.
typedef _Reading = bool Function(_Spelled move, String typed);

final List<_Reading> _names = [
  (move, typed) => move.sans.contains(typed),
  (move, typed) => move.ucis.contains(typed.toLowerCase()),
  (move, typed) => move.sans.any(
    (san) => _anyCase(san, typed) && san.toLowerCase() == typed.toLowerCase(),
  ),
];

final List<_Reading> _starts = [
  (move, typed) => move.sans.any((san) => san.startsWith(typed)),
  (move, typed) => move.ucis.any((uci) => uci.startsWith(typed.toLowerCase())),
  (move, typed) => move.sans.any(
    (san) =>
        _anyCase(san, typed) &&
        san.toLowerCase().startsWith(typed.toLowerCase()),
  ),
];

/// Whether [typed] may be read against [san] in any case: `nf3` is the
/// knight, but a capital piece letter is a piece, so `Bc4` is never the b
/// pawn's capture.
bool _anyCase(String san, String typed) =>
    typed.isEmpty ||
    !'KQRBN'.contains(typed[0]) ||
    san[0] == san[0].toUpperCase();

/// The moves the first reading of [typed] that finds any finds, as UCI.
List<String> _firstReading(
  List<_Reading> readings,
  List<_Spelled> moves,
  String typed,
) {
  for (final reads in readings) {
    final found = {
      for (final move in moves)
        if (reads(move, typed)) move.uci,
    };
    if (found.isNotEmpty) return found.toList();
  }
  return const [];
}

/// Whether another move than [named] is written as [typed] and more: `OO`
/// is the start of `OOO`.
bool _couldGoOn(List<_Spelled> moves, String typed, String named) {
  final start = typed.toLowerCase();
  return moves.any(
    (move) =>
        move.uci != named &&
        [...move.sans, ...move.ucis].any(
          (spelling) =>
              spelling.length > start.length &&
              spelling.toLowerCase().startsWith(start),
        ),
  );
}

/// The queen, when [candidates] are the promotions of one pawn and nothing
/// else: `e7e8q`, `e7e8r`, `e7e8b`, `e7e8n` all start `e7e8`.
String? _queenOf(List<String> candidates) {
  if (candidates.isEmpty || candidates.any((uci) => uci.length != 5)) {
    return null;
  }
  final squares = candidates.first.substring(0, 4);
  if (candidates.any((uci) => !uci.startsWith(squares))) return null;
  return '${squares}q';
}

/// A move as typed with the optional marks and the dashes gone, and a
/// castling zero read as the letter: `0-0` is `OO`, `Nxe5+` is `Ne5`.
String _plain(String text) =>
    text.replaceAll(RegExp(r'[x:=+#!?\s-]'), '').replaceAll('0', 'O');

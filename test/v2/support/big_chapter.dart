import 'dart:math';

import 'package:dartchess/dartchess.dart';

/// A repertoire chapter of [games] lines, each opening 1. d4 d5 and going
/// on for [plies] plies of legal moves a seeded random walk picks: a book's
/// shape — many lines sharing an opening, then parting — at a size a widget
/// test can hold. Kept well under 64 KiB, because a larger text is read on
/// another isolate, which a widget test's fake clock never lets finish.
String bigChapter({int games = 120, int plies = 16, int seed = 7}) {
  final random = Random(seed);
  final text = StringBuffer('// Book\n// Color: White\n\n');
  for (var game = 1; game <= games; game++) {
    text
      ..writeln('[Event "Line $game"]')
      ..writeln('[Result "*"]')
      ..writeln()
      ..writeln('${_numbered(_walk(random, plies))} *')
      ..writeln();
  }
  return text.toString();
}

List<String> _walk(Random random, int plies) {
  Position position = Chess.initial;
  final sans = <String>[];
  for (final uci in ['d2d4', 'd7d5']) {
    final (next, san) = position.makeSan(Move.parse(uci)!);
    position = next;
    sans.add(san);
  }
  while (sans.length < plies) {
    final moves = _legal(position);
    if (moves.isEmpty) break;
    final (next, san) = position.makeSan(moves[random.nextInt(moves.length)]);
    position = next;
    sans.add(san);
  }
  return sans;
}

/// Every legal move, a pawn reaching the last rank becoming a queen.
List<Move> _legal(Position position) => [
  for (final MapEntry(key: from, value: targets) in position.legalMoves.entries)
    for (final to in targets.squares)
      NormalMove(
        from: from,
        to: to,
        promotion:
            position.board.roleAt(from) == Role.pawn &&
                (to.rank == Rank.first || to.rank == Rank.eighth)
            ? Role.queen
            : null,
      ),
];

String _numbered(List<String> sans) => [
  for (final (ply, san) in sans.indexed)
    ply.isEven ? '${ply ~/ 2 + 1}. $san' : san,
].join(' ');

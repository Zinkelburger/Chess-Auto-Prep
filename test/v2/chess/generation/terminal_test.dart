import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/generation/search_node.dart';
import 'package:chess_auto_prep/v2/chess/generation/terminal.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

Position positionOf(String fen) => Chess.fromSetup(Setup.parseFen(fen));

/// Plays [sans] and returns the position after each move, the starting one
/// first, the way the search's own path does.
List<Position> lineFrom(Position start, List<String> sans) {
  final line = [start];
  for (final san in sans) {
    line.add(line.last.play(line.last.parseSan(san)!));
  }
  return line;
}

List<String> keysOf(List<Position> line) => [
  for (final position in line) repetitionKey(Fen(position.fen)),
];

TerminalKind? kindAfter(List<String> sans) {
  final line = lineFrom(Chess.initial, sans);
  return terminalKind(line.last, keysOf(line));
}

void main() {
  test('the key is placement, side, castling and en passant', () {
    final after = lineFrom(Chess.initial, ['e4']).last;
    expect(
      repetitionKey(Fen(after.fen)),
      'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq -',
    );
  });

  test('the clocks are not part of the key', () {
    final fresh = positionOf('4k3/8/8/8/8/8/3R4/4K3 w - - 0 1');
    final stale = positionOf('4k3/8/8/8/8/8/3R4/4K3 w - - 80 41');
    expect(repetitionKey(Fen(fresh.fen)), repetitionKey(Fen(stale.fen)));
  });

  test('claims the draw on the third occurrence, not the second', () {
    expect(kindAfter(['Nf3', 'Nf6', 'Ng1', 'Ng8']), isNull);
    expect(
      kindAfter(['Nf3', 'Nf6', 'Ng1', 'Ng8', 'Nf3', 'Nf6', 'Ng1', 'Ng8']),
      TerminalKind.repetition,
    );
  });

  test('counts only the path it is given, never a sibling line', () {
    final shuffle = ['Nf3', 'Nf6', 'Ng1', 'Ng8'];
    final line = lineFrom(Chess.initial, shuffle);
    final sibling = lineFrom(Chess.initial, [...shuffle, 'Nc3', 'Nc6']);
    // The start position has been seen twice down each line, and the two
    // lines never lend each other an occurrence.
    expect(terminalKind(line.last, keysOf(line)), isNull);
    expect(terminalKind(sibling.last, keysOf(sibling)), isNull);
    expect(
      keysOf(sibling).where((key) => key == keysOf(line).first),
      hasLength(2),
    );
  });

  test('claims the draw on the hundredth quiet half-move', () {
    final position = positionOf('4k3/8/8/8/8/8/3R4/4K3 w - - 99 60');
    final after = position.play(position.parseSan('Rd3')!);
    expect(terminalKind(position, [repetitionKey(Fen(position.fen))]), isNull);
    expect(
      terminalKind(after, [repetitionKey(Fen(after.fen))]),
      TerminalKind.fiftyMoveRule,
    );
  });

  test('checkmate comes before any draw claim', () {
    final mate = positionOf('7k/5KQ1/8/8/8/8/8/8 b - - 99 60');
    expect(
      terminalKind(mate, [repetitionKey(Fen(mate.fen))]),
      TerminalKind.checkmate,
    );
  });

  test('knows stalemate and a bare board', () {
    final stalemate = positionOf('7k/5Q2/6K1/8/8/8/8/8 b - - 0 1');
    final bare = positionOf('4k3/8/8/8/8/8/8/4K3 w - - 0 1');
    expect(
      terminalKind(stalemate, [repetitionKey(Fen(stalemate.fen))]),
      TerminalKind.stalemate,
    );
    expect(
      terminalKind(bare, [repetitionKey(Fen(bare.fen))]),
      TerminalKind.insufficientMaterial,
    );
  });
}

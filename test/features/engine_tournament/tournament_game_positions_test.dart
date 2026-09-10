import 'package:chess_auto_prep/features/engine_tournament/services/tournament_game_positions.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('replays mainlines and ignores comments and variations', () {
    final fens = tournamentFinalPositions('''
[Event "Game one"]
[Result "0-1"]

1. f3 {first move} e5 (1... d5) 2. g4 Qh4# 0-1

[Event "Game two"]
[Result "*"]

1. e4 *
''');
    expect(fens, hasLength(2));
    expect(Chess.fromSetup(Setup.parseFen(fens.first!)).isCheckmate, isTrue);
    expect(
      fens.last,
      'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
    );
  });

  test('uses FEN starts and leaves invalid mainlines unavailable', () {
    const start = '7k/8/6K1/8/8/8/8/R7 w - - 0 31';
    final fens = tournamentFinalPositions('''
[Event "From position"]
[SetUp "1"]
[FEN "$start"]
[Result "1-0"]

31. Ra8# 1-0

[Event "Broken game"]
[Result "*"]

1. e5 *
''');
    expect(fens, hasLength(2));
    expect(Chess.fromSetup(Setup.parseFen(fens.first!)).isCheckmate, isTrue);
    expect(fens.last, isNull);
  });
}

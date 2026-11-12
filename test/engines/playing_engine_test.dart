import 'package:chess_auto_prep/engines/playing_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a move with no limit is searched twelve plies; any limit of its own '
      'is the only one', () {
    expect(const MoveBudget().command, 'go depth 12');
    expect(const MoveBudget(milliseconds: 500).command, 'go movetime 500');
    expect(const MoveBudget(depth: 5).command, 'go depth 5');
    expect(const MoveBudget(nodes: 100).command, 'go nodes 100');
    expect(
      const MoveBudget(whiteTime: 60000, blackTime: 50000).command,
      'go wtime 60000 btime 50000 winc 0 binc 0',
    );
  });

  test('numbers are held to what a UCI engine reads', () {
    expect(const MoveBudget(depth: 500).command, 'go depth 128');
    expect(
      const MoveBudget(
        whiteTime: 1000,
        blackTime: 1000,
        increment: 2000,
      ).command,
      'go wtime 1000 btime 1000 winc 2000 binc 2000',
    );
  });
}

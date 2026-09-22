/// The stored-analysis codec: replaying a mainline, reading `[%eval]` /
/// `[%pv]` / `[%maia*]` tokens back into a series and writing them onto a
/// game so the next load reads what the last pass saw.
library;

import 'package:chess_auto_prep/chess_core/analysis/game_eval_annotations.dart';
import 'package:chess_auto_prep/chess_core/analysis/move_eval.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

const _header =
    '[Event "Test"]\n'
    '[White "A"]\n'
    '[Black "B"]\n'
    '[Result "*"]\n'
    '\n';

void main() {
  group('start position', () {
    test('a FEN header counts only with SetUp "1"', () {
      const fen = '8/8/8/8/8/8/8/K6k w - - 0 1';
      expect(setupFenOf({'FEN': fen}), isNull);
      expect(setupFenOf({'FEN': fen, 'SetUp': '1'}), fen);
      expect(setupFenOf({'FEN': fen, 'Setup': '1'}), fen);
      expect(gameStartPosition({'FEN': fen}), Chess.initial);
      expect(gameStartPosition({'FEN': fen, 'SetUp': '1'}).fen, fen);
    });
  });

  group('replayMainline', () {
    test('numbers plies through null moves and skips them', () {
      final game = PgnGame.parsePgn('${_header}1. d4 -- 2. Nf3 Nf6 *');
      final replay = replayMainline(
        Chess.initial,
        game.moves.mainline().toList(),
      );
      expect(replay.plies.map((p) => p.node.san), ['d4', 'Nf3', 'Nf6']);
      expect(replay.plies.map((p) => p.ply), [1, 3, 4]);
      expect(replay.plies.first.before, Chess.initial);
      expect(replay.plies.first.after.turn, Side.black);
      expect(replay.end, replay.plies.last.after);
    });

    test('stops at the first move that does not play', () {
      final game = PgnGame.parsePgn('${_header}1. e4 e5 2. Ke3 Nf6 *');
      final replay = replayMainline(
        Chess.initial,
        game.moves.mainline().toList(),
      );
      expect(replay.plies.map((p) => p.node.san), ['e4', 'e5']);
    });
  });

  group('writing tokens onto a move', () {
    MoveEval eval({List<String> bestLine = const []}) => MoveEval(
      ply: 1,
      san: 'e4',
      fenBefore: Chess.initial.fen,
      fenAfter: Chess.initial.play(Chess.initial.parseSan('e4')!).fen,
      scoreCp: 25,
      winningChance: 0.04,
      bestLine: bestLine,
      maiaTopMove: 'd4',
      maiaTopProb: 0.4,
      depth: 12,
    );

    test('a move without a comment gets one', () {
      final node = PgnNodeData(san: 'e4');
      writeEvalComment(node, eval(bestLine: const ['e5', 'Nf3']));
      expect(node.comments, [
        '[%eval 0.25,12] [%pv e5,Nf3] [%maiatop d4,0.400]',
      ]);
      writeMaiaComment(node, 0.5);
      expect(node.comments!.single, endsWith('[%maia 0.500]'));
    });

    test('an existing comment keeps its prose and replaces its tokens', () {
      final node = PgnNodeData(
        san: 'e4',
        comments: ['[%eval 9.99] a fine move', 'second'],
      );
      writeEvalComment(node, eval());
      expect(node.comments, [
        '[%eval 0.25,12] a fine move [%maiatop d4,0.400]',
        'second',
      ]);
      writeMaiaComment(node, 0.5);
      writeMaiaComment(node, 0.25);
      expect(node.comments!.first, endsWith('[%maia 0.250]'));
      expect('[%maia '.allMatches(node.comments!.first), hasLength(1));
    });
  });

  group('parseCachedEvals', () {
    test('reads back what writeEvalComment wrote, classified', () {
      final game = PgnGame.parsePgn('${_header}1. e4 e5 2. Ke2 *');
      final replay = replayMainline(
        Chess.initial,
        game.moves.mainline().toList(),
      );
      final scores = [30, 20, -250];
      for (var i = 0; i < replay.plies.length; i++) {
        final ply = replay.plies[i];
        writeEvalComment(
          ply.node,
          MoveEval(
            ply: ply.ply,
            san: ply.node.san,
            fenBefore: ply.before.fen,
            fenAfter: ply.after.fen,
            scoreCp: scores[i],
            winningChance: cpToWinningChance(scores[i], null),
            depth: 10,
          ),
        );
      }
      final text = '$_header${game.makePgn()}';
      final parsed = parseCachedEvals(text);
      expect(parsed, isNotNull);
      expect(parsed!.totalMoves, 3);
      expect(parsed.startWinChance, initialWinChance());
      expect(parsed.evals.map((e) => e.scoreCp), scores);
      expect(parsed.evals.map((e) => e.depth), [10, 10, 10]);
      expect(parsed.evals.last.classification, MoveClassification.blunder);
      expect(parsed.evals.first.classification, MoveClassification.normal);
    });

    test('too many unscored plies means the game is not analyzed', () {
      expect(
        parseCachedEvals(
          '${_header}1. e4 {[%eval 0.3]} e5 2. Nf3 Nc6 3. Bb5 *',
        ),
        isNull,
      );
      expect(parseCachedEvals('${_header}*'), isNull);
    });
  });
}

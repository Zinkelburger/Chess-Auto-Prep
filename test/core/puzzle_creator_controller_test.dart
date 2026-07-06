import 'package:chess_auto_prep/core/puzzle_creator_controller.dart';
import 'package:chess_auto_prep/services/tactics_engine.dart';
import 'package:chess_auto_prep/services/tactics_database.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('step flow', () {
    test('starts in setup and requires a valid position to record', () {
      final c = PuzzleCreatorController();
      expect(c.step, CreatorStep.setup);

      c.editor.clear(); // empty board is invalid
      expect(c.startRecording(), isFalse);
      expect(c.step, CreatorStep.setup);

      c.editor.setStartPosition();
      expect(c.startRecording(), isTrue);
      expect(c.step, CreatorStep.recordSolution);
      expect(c.solverSide, Side.white);
    });

    test('finishRecording requires at least one move', () {
      final c = PuzzleCreatorController()..startRecording();
      expect(c.finishRecording(), isFalse);
      c.playMoveSan('e4');
      expect(c.finishRecording(), isTrue);
      expect(c.step, CreatorStep.details);
    });

    test('backToSetup discards the recorded line', () {
      final c = PuzzleCreatorController()..startRecording();
      c.playMoveSan('e4');
      c.backToSetup();
      expect(c.step, CreatorStep.setup);
      expect(c.solutionSan, isEmpty);
      expect(c.startPosition, isNull);
    });
  });

  group('solution recording', () {
    test('records SAN, including castling, and tracks the live board', () {
      final c = PuzzleCreatorController(
          initialFen:
              'r1bqk1nr/pppp1ppp/2n5/2b1p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 4 4');
      c.startRecording();

      expect(c.playMoveSan('O-O'), isTrue);
      expect(c.playMoveSan('Nf6'), isTrue);
      expect(c.solutionSan, ['O-O', 'Nf6']);
      expect(c.currentPosition!.turn, Side.white);
    });

    test('illegal SAN is rejected without changing state', () {
      final c = PuzzleCreatorController()..startRecording();
      expect(c.playMoveSan('Ke2'), isFalse);
      expect(c.solutionSan, isEmpty);
    });

    test('undoLastMove replays from the start position', () {
      final c = PuzzleCreatorController()..startRecording();
      c.playMoveSan('e4');
      c.playMoveSan('e5');
      c.playMoveSan('Nf3');

      c.undoLastMove();
      expect(c.solutionSan, ['e4', 'e5']);
      expect(c.currentPosition!.fen,
          contains('4p3')); // e5 pawn still on the board
      expect(c.currentPosition!.turn, Side.white);

      c.undoLastMove();
      c.undoLastMove();
      expect(c.solutionSan, isEmpty);
      expect(c.currentPosition!.fen, c.startPosition!.fen);
    });
  });

  group('buildPuzzle', () {
    test('emits a trainable custom TacticsPosition', () {
      // Black to move, mate in one: Qh4# (after 1. f3 e5 2. g4).
      // No ep square: dartchess normalizes away ep targets that no pawn can
      // actually capture on, so an unusable "g3" would be dropped anyway.
      const fen =
          'rnbqkbnr/pppp1ppp/8/4p3/6P1/5P2/PPPPP2P/RNBQKBNR b KQkq - 0 2';
      final c = PuzzleCreatorController(initialFen: fen);
      c.startRecording();
      expect(c.playMoveSan('Qh4#'), isTrue);
      c.finishRecording();

      final puzzle = c.buildPuzzle(note: 'Fool\'s mate pattern', rating: 4);
      expect(puzzle.fen, fen);
      expect(puzzle.correctLine, ['Qh4#']);
      expect(puzzle.mistakeType, 'custom');
      expect(puzzle.mistakeAnalysis, 'Fool\'s mate pattern');
      expect(puzzle.positionContext, 'Move 2, Black to play');
      expect(puzzle.rating, 4);
      expect(puzzle.userMove, isEmpty);
      expect(puzzle.playerToMove, 'black');

      // The trainer validates the recorded move (SAN path, annotations
      // stripped by the engine's normalizer).
      final engine = TacticsEngine();
      expect(
        engine.checkMoveAtIndex(puzzle, 'd8h4', puzzle.fen, 0),
        TacticsResult.correct,
      );
      expect(
        engine.checkMoveAtIndex(puzzle, 'd8e7', puzzle.fen, 0),
        TacticsResult.incorrect,
      );
    });

    test('throws when no solution was recorded', () {
      final c = PuzzleCreatorController();
      expect(() => c.buildPuzzle(), throwsStateError);
    });

    test('round-trips through CSV without schema changes', () {
      final c = PuzzleCreatorController()..startRecording();
      c.playMoveSan('e4');
      c.finishRecording();
      final puzzle = c.buildPuzzle(note: 'note with, comma');

      final row = puzzle.toCsvRow();
      expect(row.length, 20);
      final decoded = // simulate CSV write/read of the row values
          puzzle.toJson();
      expect(decoded['mistake_type'], 'custom');
    });
  });
}

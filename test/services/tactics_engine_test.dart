import 'package:chess_auto_prep/models/tactics_position.dart';
import 'package:chess_auto_prep/services/tactics_database.dart';
import 'package:chess_auto_prep/services/tactics_engine.dart';
import 'package:flutter_test/flutter_test.dart';

const _scholarsMateFen =
    'r1bqkb1r/pppp1ppp/2n2n2/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w KQkq - 4 4';

const _startFen =
    'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

const _afterE4E5Nf3Nc6 =
    'r1bqkb1r/pppp1ppp/2n2n2/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 4';

TacticsPosition _position({
  required String fen,
  required List<String> correctLine,
}) {
  return TacticsPosition(
    fen: fen,
    userMove: '??',
    correctLine: correctLine,
    mistakeType: '??',
    mistakeAnalysis: 'test',
    positionContext: 'Move 1, White to play',
    gameWhite: 'White',
    gameBlack: 'Black',
    gameResult: '1-0',
    gameDate: '2024.01.01',
    gameId: 'test',
  );
}

void main() {
  late TacticsEngine engine;

  setUp(() {
    engine = TacticsEngine();
  });

  group('TacticsEngine.checkMoveAtIndex', () {
    test('returns correct for mate-in-1 from non-start FEN', () {
      final position = _position(
        fen: _scholarsMateFen,
        correctLine: const ['Qxf7#'],
      );

      final result = engine.checkMoveAtIndex(
        position,
        'h5f7',
        _scholarsMateFen,
        0,
      );

      expect(result, TacticsResult.correct);
    });

    test('returns correct for first move of multi-move puzzle', () {
      final position = _position(
        fen: _startFen,
        correctLine: const ['e4', 'e5', 'Nf3', 'Nc6', 'Bc4'],
      );

      final result = engine.checkMoveAtIndex(
        position,
        'e2e4',
        _startFen,
        0,
      );

      expect(result, TacticsResult.correct);
    });

    test('returns correct for last move of multi-move puzzle', () {
      final position = _position(
        fen: _startFen,
        correctLine: const ['e4', 'e5', 'Nf3', 'Nc6', 'Bc4'],
      );

      final result = engine.checkMoveAtIndex(
        position,
        'f1c4',
        _afterE4E5Nf3Nc6,
        4,
      );

      expect(result, TacticsResult.correct);
    });

    test('returns incorrect for wrong move', () {
      final position = _position(
        fen: _scholarsMateFen,
        correctLine: const ['Qxf7#'],
      );

      final result = engine.checkMoveAtIndex(
        position,
        'h5h4',
        _scholarsMateFen,
        0,
      );

      expect(result, TacticsResult.incorrect);
    });

    test('returns incorrect for illegal move string', () {
      final position = _position(
        fen: _startFen,
        correctLine: const ['e4'],
      );

      expect(
        engine.checkMoveAtIndex(position, 'e2e9', _startFen, 0),
        TacticsResult.incorrect,
      );
      expect(
        engine.checkMoveAtIndex(position, 'abc', _startFen, 0),
        TacticsResult.incorrect,
      );
    });

    test('handles UCI format (e2e4) and SAN format (e4) equivalently', () {
      final uciPosition = _position(
        fen: _startFen,
        correctLine: const ['e2e4'],
      );
      final sanPosition = _position(
        fen: _startFen,
        correctLine: const ['e4'],
      );

      expect(
        engine.checkMoveAtIndex(uciPosition, 'e2e4', _startFen, 0),
        TacticsResult.correct,
      );
      expect(
        engine.checkMoveAtIndex(sanPosition, 'e2e4', _startFen, 0),
        TacticsResult.correct,
      );
    });

    test('is insensitive to check/mate annotations (Qh7 vs Qh7+ vs Qh7#)', () {
      final position = _position(
        fen: _scholarsMateFen,
        correctLine: const ['Qxf7#'],
      );

      for (final expected in ['Qxf7', 'Qxf7+', 'Qxf7#']) {
        final annotated = _position(
          fen: _scholarsMateFen,
          correctLine: [expected],
        );
        expect(
          engine.checkMoveAtIndex(annotated, 'h5f7', _scholarsMateFen, 0),
          TacticsResult.correct,
          reason: 'expected SAN $expected should accept h5f7',
        );
      }
    });

    test('moveIndex out of range always returns incorrect without side effects',
        () {
      final position = _position(
        fen: _startFen,
        correctLine: const ['e4'],
      );

      expect(
        engine.checkMoveAtIndex(position, 'e2e4', _startFen, 1),
        TacticsResult.incorrect,
      );
      expect(position.correctLine, ['e4']);
    });
  });

  group('TacticsEngine SAN normalization via checkMoveAtIndex', () {
    test('strips +, #, !, ? annotations from expected SAN', () {
      const fenAfterE4E5 =
          'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2';

      for (final annotated in ['Nf3+', 'Nf3#', 'Nf3!', 'Nf3?', 'Nf3!?']) {
        final position = _position(
          fen: fenAfterE4E5,
          correctLine: [annotated],
        );

        expect(
          engine.checkMoveAtIndex(position, 'g1f3', fenAfterE4E5, 0),
          TacticsResult.correct,
          reason: 'annotation variant $annotated',
        );
      }
    });

    test('preserves piece prefix and coordinates', () {
      const fenAfterE4E5 =
          'rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq c6 0 2';

      final position = _position(
        fen: fenAfterE4E5,
        correctLine: const ['Nf3'],
      );

      expect(
        engine.checkMoveAtIndex(position, 'g1f3', fenAfterE4E5, 0),
        TacticsResult.correct,
      );
      expect(
        engine.checkMoveAtIndex(position, 'b1c3', fenAfterE4E5, 0),
        TacticsResult.incorrect,
      );
    });

    test('empty expected SAN never matches a legal move', () {
      final position = _position(
        fen: _startFen,
        correctLine: const [''],
      );

      expect(
        engine.checkMoveAtIndex(position, 'e2e4', _startFen, 0),
        TacticsResult.incorrect,
      );
    });
  });
}

// Phase 3: unit tests for the extracted RepertoireAuthoring collaborator.

import 'package:chess_auto_prep/core/repertoire_authoring.dart';
import 'package:chess_auto_prep/models/repertoire_line.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final authoring = RepertoireAuthoring();

  group('RepertoireAuthoring.buildGame', () {
    test('returns null for empty move lines', () {
      expect(authoring.buildGame(moveLines: const []), isNull);
    });

    test('emits standard 5 headers + movetext', () {
      final pgn = authoring.buildGame(
        event: 'My Line',
        moveLines: const ['1. e4 e5 2. Nf3'],
      )!;
      expect(pgn, contains('[Event "My Line"]'));
      expect(pgn, contains('[White "Training"]'));
      expect(pgn, contains('[Result "1-0"]'));
      expect(pgn, contains('1. e4 e5 2. Nf3'));
    });
  });

  group('RepertoireAuthoring.defaultLineTitle', () {
    test('uses first three moves when long enough', () {
      expect(
        authoring.defaultLineTitle(['e4', 'e5', 'Nf3', 'Nc6']),
        'Line: e4 e5 Nf3',
      );
    });
    test('falls back for short lines', () {
      expect(authoring.defaultLineTitle(['e4']), 'Repertoire Line');
    });
  });

  group('RepertoireAuthoring.findLineIndexForPrefix', () {
    final lines = [
      _line('a', ['e4', 'e5']),
      _line('b', ['d4', 'd5']),
    ];
    test('finds an exact-length match', () {
      expect(authoring.findLineIndexForPrefix(lines, ['d4', 'd5']), 1);
    });
    test('returns null when no exact match', () {
      expect(authoring.findLineIndexForPrefix(lines, ['e4']), isNull);
      expect(
        authoring.findLineIndexForPrefix(lines, ['e4', 'e5', 'Nf3']),
        isNull,
      );
    });
  });

  group('RepertoireAuthoring.buildNewLine', () {
    test('honors explicit title and color', () {
      final line = authoring.buildNewLine(
        moves: const ['e4', 'e5'],
        title: 'My Sicilian',
        pgnContent: '[Event "x"]\n\n1. e4 e5 *',
        index: 0,
        isWhite: false,
      );
      expect(line.name, 'My Sicilian');
      expect(line.color, 'black');
      expect(line.moves, ['e4', 'e5']);
    });

    test('derives a name when title is the generic placeholder', () {
      final line = authoring.buildNewLine(
        moves: const ['e4', 'e5', 'Nf3'],
        title: 'Repertoire Line',
        pgnContent: '[Event "x"]\n\n1. e4 e5 2. Nf3 *',
        index: 2,
        isWhite: true,
      );
      expect(line.name, 'Line: e4 e5 Nf3');
      expect(line.color, 'white');
    });
  });

  group('RepertoireAuthoring.extendLine', () {
    test('appends a move and preserves identity fields', () {
      final original = _line('keep-id', [
        'e4',
        'e5',
      ], pgn: '[Event "x"]\n\n1. e4 e5 *');
      final extended = authoring.extendLine(original, 'Nf3');
      expect(extended.id, 'keep-id');
      expect(extended.moves, ['e4', 'e5', 'Nf3']);
    });
  });

  group('RepertoireAuthoring.numberedMovetext', () {
    test('numbers from move one for the standard start', () {
      expect(
        authoring.numberedMovetext(const [
          'e4',
          'e5',
          'Nf3',
        ], startingFen: Chess.initial.fen),
        '1. e4 e5 2. Nf3',
      );
    });

    test('numbers from the starting position, Black to move included', () {
      expect(
        authoring.numberedMovetext(
          const ['c5', 'Nf3'],
          startingFen:
              'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
        ),
        '1... c5 2. Nf3',
      );
    });

    test('an empty line is empty and a bad FEN numbers from one', () {
      expect(authoring.numberedMovetext(const [], startingFen: 'x'), '');
      expect(
        authoring.numberedMovetext(const ['e4'], startingFen: 'not a fen'),
        '1. e4',
      );
    });
  });

  group('RepertoireAuthoring.rebuildLine', () {
    final old = RepertoireLine(
      id: 'line-1',
      sourcePath: '/src.pgn',
      sourceLineId: 'src-1',
      name: 'Main line',
      moves: const ['e4', 'e5'],
      color: 'white',
      startPosition: Chess.initial,
      fullPgn: '1. e4 e5',
      importance: 0.7,
      chapter: 'Open games',
      gameIndex: 3,
    );

    test('re-reads moves, comments and headers from the new text', () {
      final rebuilt = authoring.rebuildLine(
        old,
        '[Event "Edited"]\n\n1. e4 {best} e5 2. Nf3 { calm } Nc6',
      );

      expect(rebuilt.moves, ['e4', 'e5', 'Nf3', 'Nc6']);
      expect(rebuilt.comments, {'0': 'best', '2': 'calm'});
      expect(rebuilt.headers['Event'], 'Edited');
      expect(rebuilt.fullPgn, contains('2. Nf3'));
    });

    test('keeps the line\'s identity and place in the file', () {
      final rebuilt = authoring.rebuildLine(old, '1. d4 d5');

      expect(rebuilt.id, 'line-1');
      expect(rebuilt.sourcePath, '/src.pgn');
      expect(rebuilt.sourceLineId, 'src-1');
      expect(rebuilt.name, 'Main line');
      expect(rebuilt.color, 'white');
      expect(rebuilt.importance, 0.7);
      expect(rebuilt.chapter, 'Open games');
      expect(rebuilt.gameIndex, 3, reason: 'edited in place, same game');
    });
  });
}

RepertoireLine _line(String id, List<String> moves, {String pgn = ''}) =>
    RepertoireLine(
      id: id,
      name: id,
      moves: moves,
      color: 'white',
      startPosition: Chess.initial,
      fullPgn: pgn.isEmpty ? '[Event "x"]\n\n*' : pgn,
    );

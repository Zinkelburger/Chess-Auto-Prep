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
      expect(authoring.defaultLineTitle(['e4', 'e5', 'Nf3', 'Nc6']),
          'Line: e4 e5 Nf3');
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
      expect(authoring.findLineIndexForPrefix(lines, ['e4', 'e5', 'Nf3']),
          isNull);
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
      final original = _line('keep-id', ['e4', 'e5'],
          pgn: '[Event "x"]\n\n1. e4 e5 *');
      final extended = authoring.extendLine(original, 'Nf3');
      expect(extended.id, 'keep-id');
      expect(extended.moves, ['e4', 'e5', 'Nf3']);
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

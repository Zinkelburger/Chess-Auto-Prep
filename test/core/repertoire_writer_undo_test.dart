import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/core/repertoire_controller.dart';
import 'package:chess_auto_prep/core/repertoire_writer.dart';
import 'package:chess_auto_prep/features/coverage/services/coverage_suggestion_service.dart';
import 'package:chess_auto_prep/models/repertoire_metadata.dart';

void main() {
  group('RepertoireWriter undo', () {
    late Directory tempDir;
    late String filePath;
    late RepertoireController controller;
    late RepertoireWriter writer;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('repertoire_undo_test');
      filePath = '${tempDir.path}/test.pgn';
      await File(filePath).writeAsString('''
// Color: White

[Event "Line 1"]
[Date "2026-01-01"]
[White "Me"]
[Black "Opponent"]
[Result "1-0"]

1. e4 e5
''');

      controller = RepertoireController();
      await controller.setRepertoire(
        RepertoireMetadata(
          name: 'Test',
          filePath: filePath,
          lastModified: DateTime(2026, 1, 1),
        ),
      );
      writer = controller.writer;
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('undo reverses addMoveAtPosition on disk and in memory', () async {
      controller.loadMoveHistory(['e4', 'e5']);
      final before = await File(filePath).readAsString();

      await writer.addMoveAtPosition(
        fen: controller.fen,
        san: 'Nf3',
        pathFromRoot: ['e4', 'e5'],
      );
      controller.playMove('Nf3');

      expect(writer.canUndo, isTrue);
      expect(await File(filePath).readAsString(), contains('Nf3'));
      expect(controller.repertoireLines.first.moves, ['e4', 'e5', 'Nf3']);

      final undone = await writer.undo();
      expect(undone, isTrue);
      expect(writer.canUndo, isFalse);
      expect(await File(filePath).readAsString(), before);
      expect(controller.repertoireLines.first.moves, ['e4', 'e5']);
      expect(controller.currentMoveSequence, ['e4', 'e5']);
      expect(controller.openingTree!.hasMove(controller.fen, 'Nf3'), isFalse);
    });

    test('undo returns false when stack is empty', () async {
      expect(writer.canUndo, isFalse);
      expect(await writer.undo(), isFalse);
    });

    test('duplicate add does not push undo entry', () async {
      controller.loadMoveHistory(['e4']);

      await writer.addMoveAtPosition(
        fen: controller.fen,
        san: 'e5',
        pathFromRoot: ['e4'],
      );

      expect(writer.canUndo, isFalse);
    });

    test('undo stack keeps only last 20 operations', () async {
      controller.loadMoveHistory(['e4', 'e5']);

      const movesToAdd = [
        'Nf3',
        'Nc6',
        'Bb5',
        'a6',
        'Ba4',
        'Nf6',
        'O-O',
        'Be7',
        'Re1',
        'b5',
        'Bb3',
        'd6',
        'c3',
        'O-O',
        'h3',
        'Nb8',
        'd4',
        'Nbd7',
        'Nbd2',
        'Bc8',
        'Bc2',
      ];

      for (final san in movesToAdd) {
        await writer.addMoveAtPosition(
          fen: controller.fen,
          san: san,
          pathFromRoot: controller.currentMoveSequence,
        );
        controller.playMove(san);
      }

      for (var i = 0; i < 20; i++) {
        expect(await writer.undo(), isTrue, reason: 'undo #$i');
      }
      expect(writer.canUndo, isFalse);
      expect(await writer.undo(), isFalse);
    });

    test('acceptSuggestion undo removes moves one at a time', () async {
      controller.loadMoveHistory(['e4', 'e5']);

      const suggestion = SuggestedLine(
        gap: GapCandidate(
          pathToGap: ['e4', 'e5'],
          fen: '',
          type: GapType.tooShallow,
          gameCount: 1,
          coverageImpact: 0.1,
        ),
        fullMoves: ['e4', 'e5', 'Nf3', 'Nc6'],
        newMoves: ['Nf3', 'Nc6'],
        coverageGain: 0.1,
        score: 1.0,
        source: 'test',
      );

      await writer.acceptSuggestion(suggestion);
      expect(controller.repertoireLines.first.moves, [
        'e4',
        'e5',
        'Nf3',
        'Nc6',
      ]);
      expect(writer.canUndo, isTrue);

      expect(await writer.undo(), isTrue);
      expect(controller.repertoireLines.first.moves, ['e4', 'e5', 'Nf3']);
      expect(controller.currentMoveSequence, ['e4', 'e5', 'Nf3']);

      expect(await writer.undo(), isTrue);
      expect(controller.repertoireLines.first.moves, ['e4', 'e5']);
      expect(controller.currentMoveSequence, ['e4', 'e5']);
      expect(writer.canUndo, isFalse);
    });

    test('clearUndoStack on loadRepertoire', () async {
      controller.loadMoveHistory(['e4', 'e5']);
      await writer.addMoveAtPosition(
        fen: controller.fen,
        san: 'Nf3',
        pathFromRoot: ['e4', 'e5'],
      );
      expect(writer.canUndo, isTrue);

      await controller.loadRepertoire();
      expect(writer.canUndo, isFalse);
    });
  });
}

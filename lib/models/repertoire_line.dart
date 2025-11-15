/// Repertoire training line model
/// Represents a single trainable line extracted from PGN mainline
library;

import 'package:dartchess_webok/dartchess_webok.dart';

class RepertoireLine {
  final String id;
  final String name; // e.g., "French Defense - Main Line"
  final List<String> moves; // SAN moves: ["e4", "e6", "d4", "d5", ...]
  final String color; // "white" or "black" - which side we're training
  final Position startPosition; // Usually Chess.initial
  final String fullPgn; // Original PGN for reference
  final Map<String, String> comments; // Move comments keyed by move index
  final List<String> variations; // Sub-variations as strings for reference

  RepertoireLine({
    required this.id,
    required this.name,
    required this.moves,
    required this.color,
    required this.startPosition,
    required this.fullPgn,
    this.comments = const {},
    this.variations = const [],
  });

  /// Creates a training question at the specified move index
  /// Returns the position where the user needs to make their move
  TrainingQuestion createTrainingQuestion(int moveIndex) {
    if (moveIndex >= moves.length) {
      throw ArgumentError('Move index out of range');
    }

    // Build position up to the move before the target move
    Position position = startPosition;
    final leadupMoves = <String>[];

    for (int i = 0; i < moveIndex; i++) {
      final move = position.parseSan(moves[i]);
      if (move != null) {
        leadupMoves.add(moves[i]);
        position = position.play(move);
      } else {
        throw StateError('Invalid move in repertoire: ${moves[i]}');
      }
    }

    final correctMove = moves[moveIndex];
    final isWhiteToMove = position.turn == Side.white;

    return TrainingQuestion(
      lineId: id,
      lineName: name,
      position: position,
      leadupMoves: leadupMoves,
      correctMove: correctMove,
      isWhiteToMove: isWhiteToMove,
      moveIndex: moveIndex,
      comment: comments[moveIndex.toString()],
    );
  }

  /// Gets the total number of trainable moves in this line
  int get totalMoves => moves.length;

  /// Checks if this line trains the specified color
  bool trainsColor(String colorToTrain) => color == colorToTrain;

  @override
  String toString() => 'RepertoireLine($name: ${moves.join(" ")})';
}

class TrainingQuestion {
  final String lineId;
  final String lineName;
  final Position position;
  final List<String> leadupMoves;
  final String correctMove;
  final bool isWhiteToMove;
  final int moveIndex;
  final String? comment;

  TrainingQuestion({
    required this.lineId,
    required this.lineName,
    required this.position,
    required this.leadupMoves,
    required this.correctMove,
    required this.isWhiteToMove,
    required this.moveIndex,
    this.comment,
  });

  /// Creates a user-friendly question text
  String get questionText {
    final colorText = isWhiteToMove ? 'White' : 'Black';

    if (leadupMoves.isEmpty) {
      return 'Playing as $colorText: What is your opening move?';
    } else {
      final lastMoves = leadupMoves.length >= 2
          ? leadupMoves.sublist(leadupMoves.length - 2).join(' ')
          : leadupMoves.last;
      return 'Playing as $colorText after $lastMoves: What do you play?';
    }
  }

  /// Validates if the user's move matches the correct move
  bool validateMove(String userMove) {
    // Parse the user's move and check if it matches the correct move
    final userParsed = position.parseSan(userMove);
    final correctParsed = position.parseSan(correctMove);

    if (userParsed == null || correctParsed == null) {
      return false;
    }

    return userParsed == correctParsed;
  }

  @override
  String toString() => 'TrainingQuestion($questionText -> $correctMove)';
}
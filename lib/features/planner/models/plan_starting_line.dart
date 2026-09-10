import 'package:dartchess/dartchess.dart';

import '../../../utils/fen_utils.dart';
import '../../../utils/movetext_builder.dart';

/// A named, legal move path from the initial position to a build root.
class PlanStartingLine {
  PlanStartingLine({this.name = '', required List<String> moves})
    : moves = List.unmodifiable(moves);

  final String name;
  final List<String> moves;

  String get text {
    final movetext = buildNumberedMovetext(moves, compact: true);
    return name.isEmpty ? movetext : '$name | $movetext';
  }

  /// One starting line per row, optionally `Chapter name | 1.d4 Nf6 ...`.
  /// Never silently accepts a legal prefix of an invalid line.
  static List<PlanStartingLine> parse(String text) {
    final result = <PlanStartingLine>[];
    for (final (index, raw) in text.split('\n').indexed) {
      if (raw.trim().isEmpty) continue;
      final separator = raw.indexOf('|');
      final name = separator < 0 ? '' : raw.substring(0, separator).trim();
      final body = separator < 0 ? raw : raw.substring(separator + 1);
      final tokens = body
          .replaceAll(RegExp(r'\d+\.(?:\.\.)?'), ' ')
          .trim()
          .split(RegExp(r'\s+'))
          .where((t) => t.isNotEmpty)
          .toList();
      if (tokens.isNotEmpty &&
          {'*', '1-0', '0-1', '1/2-1/2'}.contains(tokens.last)) {
        tokens.removeLast();
      }
      Position position = Chess.initial;
      final moves = <String>[];
      for (final token in tokens) {
        final move = position.parseSan(token);
        if (move == null) {
          throw FormatException(
            'Line ${index + 1}: “$token” is not a legal move here.',
          );
        }
        moves.add(position.makeSan(move).$2);
        position = position.play(move);
      }
      result.add(PlanStartingLine(name: name, moves: moves));
    }
    return result.isEmpty ? [PlanStartingLine(moves: const [])] : result;
  }

  /// Reject duplicate roots and ancestor/descendant starts before planning.
  /// Both otherwise build overlapping continuations into different chapters.
  static void validate(List<PlanStartingLine> lines) {
    if (lines.isEmpty) throw const FormatException('Add a starting line.');
    final positions = <String, int>{};
    for (final (i, line) in lines.indexed) {
      Position position = Chess.initial;
      for (final san in line.moves) {
        final move = position.parseSan(san);
        if (move == null) {
          throw FormatException('Line ${i + 1}: illegal move “$san”.');
        }
        position = position.play(move);
      }
      final key = normalizeFen(position.fen);
      final earlier = positions[key];
      if (earlier != null) {
        throw FormatException(
          'Lines ${earlier + 1} and ${i + 1} reach the same position. Keep one starting line.',
        );
      }
      positions[key] = i;
      for (var j = 0; j < i; j++) {
        final other = lines[j].moves;
        final length = other.length < line.moves.length
            ? other.length
            : line.moves.length;
        if (List.generate(
          length,
          (k) => other[k] == line.moves[k],
        ).every((same) => same)) {
          throw FormatException(
            'Lines ${j + 1} and ${i + 1} overlap. Keep the earlier start or use separate branches.',
          );
        }
      }
    }
  }
}

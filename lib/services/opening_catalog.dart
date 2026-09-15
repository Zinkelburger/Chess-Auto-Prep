/// The bundled opening book as a flat list of named lines, for pickers and
/// labels that want every entry rather than a position lookup.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

import '../utils/movetext_builder.dart';
import 'opening_tsv.dart';

/// One named line, not one code: several distinct tabiyas can share an ECO.
class CatalogOpening {
  const CatalogOpening({
    required this.eco,
    required this.name,
    required this.moves,
  });

  final String eco;
  final String name;

  /// SAN moves from the initial position, each legal after the previous.
  final List<String> moves;

  String get movetext => buildNumberedMovetext(moves, compact: true);

  /// SAN moves of a numbered movetext (`1. e4 c5 2. Nf3`), each replayed and
  /// re-serialized so the stored spelling is dartchess's own.
  ///
  /// Throws a [FormatException] on the first illegal or unparseable token.
  static List<String> parseMoves(String text) {
    final tokens = text
        .replaceAll(RegExp(r'\d+\.(?:\.\.)?'), ' ')
        .trim()
        .split(RegExp(r'\s+'));
    Position position = Chess.initial;
    final moves = <String>[];
    for (final token in tokens.where((t) => t.isNotEmpty)) {
      final move = position.parseSan(token);
      if (move == null) throw FormatException('Illegal move: $token');
      moves.add(position.makeSan(move).$2);
      position = position.play(move);
    }
    return moves;
  }

  /// The position after [moves], replayed on each call.
  Position get position {
    Position pos = Chess.initial;
    for (final san in moves) {
      pos = pos.play(pos.parseSan(san)!);
    }
    return pos;
  }
}

/// Every line in the TSV [contents], in file order.
///
/// Isolate-safe: no instance state captured.
List<CatalogOpening> parseOpeningCatalog(List<String> contents) => [
  for (final row in parseOpeningTsvRows(contents))
    CatalogOpening(
      eco: row.eco,
      name: row.name,
      moves: CatalogOpening.parseMoves(row.movetext),
    ),
];

/// Lazily loads and caches the bundled catalog, parsed off the main isolate.
abstract final class OpeningCatalog {
  static Future<List<CatalogOpening>>? _loaded;
  static Future<List<CatalogOpening>> load() => _loaded ??= _load();

  static Future<List<CatalogOpening>> _load() async =>
      compute(parseOpeningCatalog, await loadOpeningTsvVolumes());
}

import 'dart:convert';

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../utils/movetext_builder.dart';

/// One named line, not one code: several distinct tabiyas can share an ECO.
class CatalogOpening {
  const CatalogOpening({
    required this.eco,
    required this.name,
    required this.moves,
  });

  final String eco;
  final String name;
  final List<String> moves;
  String get movetext => buildNumberedMovetext(moves, compact: true);

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

  Position get position {
    Position pos = Chess.initial;
    for (final san in moves) {
      pos = pos.play(pos.parseSan(san)!);
    }
    return pos;
  }
}

List<CatalogOpening> parseOpeningCatalog(List<String> contents) => [
  for (final content in contents)
    for (final row in const LineSplitter().convert(content))
      if (row.isNotEmpty && !row.startsWith('eco\t'))
        if (row.split('\t') case [final eco, final name, final moves, ...])
          CatalogOpening(
            eco: eco,
            name: name,
            moves: CatalogOpening.parseMoves(moves),
          ),
];

class OpeningCatalog {
  static Future<List<CatalogOpening>>? _loaded;
  static Future<List<CatalogOpening>> load() => _loaded ??= _load();

  static Future<List<CatalogOpening>> _load() async {
    final contents = await Future.wait([
      for (final volume in ['a', 'b', 'c', 'd', 'e'])
        rootBundle.loadString('assets/data/openings/$volume.tsv'),
    ]);
    return compute(parseOpeningCatalog, contents);
  }
}

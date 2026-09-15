/// The bundled lichess opening TSVs (github.com/lichess-org/chess-openings,
/// CC0): where they live and how their rows are read.
///
/// Shared by the position-keyed [OpeningBook] and the line-listing
/// [OpeningCatalog], which read the same five files for different indexes.
library;

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

/// One row of `eco / name / pgn`, columns trimmed, movetext still in PGN
/// notation (`1. e4 c5 2. Nf3`).
typedef OpeningTsvRow = ({String eco, String name, String movetext});

/// The ECO volumes the book is split into, one asset file each.
const List<String> openingTsvVolumes = ['a', 'b', 'c', 'd', 'e'];

/// Asset path of one volume's TSV.
String openingTsvAssetPath(String volume) => 'assets/data/openings/$volume.tsv';

/// The text of every volume, in [openingTsvVolumes] order.
Future<List<String>> loadOpeningTsvVolumes() => Future.wait([
  for (final volume in openingTsvVolumes)
    rootBundle.loadString(openingTsvAssetPath(volume)),
]);

/// Every data row across [contents], in file order. The `eco` header row,
/// blank lines and rows with fewer than three columns are skipped.
///
/// Isolate-safe: no instance state captured.
Iterable<OpeningTsvRow> parseOpeningTsvRows(List<String> contents) sync* {
  for (final content in contents) {
    for (final row in const LineSplitter().convert(content)) {
      if (row.isEmpty || row.startsWith('eco\t')) continue;
      if (row.split('\t') case [final eco, final name, final movetext, ...]) {
        yield (eco: eco.trim(), name: name.trim(), movetext: movetext);
      }
    }
  }
}

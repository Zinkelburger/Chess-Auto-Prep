/// Serializes a draft [MoveTree] into the app's repertoire-file format so a
/// draft can be saved as a re-openable library entry (instead of only being
/// merged into the active repertoire).
///
/// The repertoire format is a `//`-comment header preamble followed by one PGN
/// game per line. We therefore flatten the draft tree into root-to-leaf lines
/// (the same shape `RepertoireService.parseRepertoirePgn` expects) and emit one
/// game each.
///
/// Pure / synchronous — unit-tested via a parse round-trip.
library;

import '../../models/move_tree.dart';

/// Enumerate every root-to-leaf line in [tree] as a SAN sequence.
List<List<String>> enumerateLines(MoveTree tree) {
  final out = <List<String>>[];
  void walk(MoveNode node, List<String> acc) {
    final path = [...acc, node.san];
    if (node.children.isEmpty) {
      out.add(path);
      return;
    }
    for (final child in node.children) {
      walk(child, path);
    }
  }

  for (final root in tree.roots) {
    walk(root, const []);
  }
  return out;
}

/// Build repertoire-file content (header + one game per line) for [tree].
String draftToRepertoireFile(
  MoveTree tree, {
  required String name,
  required bool isWhite,
}) {
  final color = isWhite ? 'white' : 'black';
  final created = DateTime.now().toString().split('.').first;
  final buffer = StringBuffer()
    ..writeln('// $name Repertoire')
    ..writeln('// Color: $color')
    ..writeln('// Created on $created')
    ..writeln('// Source: built from games')
    ..writeln();

  final lines = enumerateLines(tree);
  for (var i = 0; i < lines.length; i++) {
    final moveText = MoveTree.fromMoves(lines[i]).toPgnMoveText();
    if (moveText.isEmpty) continue;
    buffer
      ..writeln('[Event "$name – line ${i + 1}"]')
      ..writeln('[White "${isWhite ? 'Me' : 'Opponent'}"]')
      ..writeln('[Black "${isWhite ? 'Opponent' : 'Me'}"]')
      ..writeln('[Result "*"]')
      ..writeln()
      ..writeln('$moveText *')
      ..writeln();
  }

  return buffer.toString();
}

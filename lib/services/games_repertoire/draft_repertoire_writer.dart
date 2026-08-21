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
import '../../utils/movetext_builder.dart';

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

/// Whether the final move of [line] was played by the repertoire owner's
/// side. A line that ends on an *opponent* move is a gap — the user's games
/// ran out before they ever answered it.
bool lineEndsWithMyMove(List<String> line, {required bool isWhite}) {
  if (line.isEmpty) return false;
  final whiteMovedLast = line.length.isOdd;
  return isWhite ? whiteMovedLast : !whiteMovedLast;
}

/// Numbered label for the final move of [line], e.g. "6...Bg4" or "7.Nf3"
/// (standard-start numbering — merge is blocked for custom-start repertoires).
String lastMoveLabel(List<String> line) =>
    formatMoveAtPly(line.length - 1, line.last, compact: true);

/// Comment stamped on the final move of a gap line so the PGN pane explains
/// why the line ends mid-conversation.
const String kGapLineComment =
    'Your games ended here with no reply — pick an answer.';

/// One PGN game per draft [lines] entry, titled for the Lines browser:
/// finished lines get "[titlePrefix] — line N" (numbering continues from
/// [startIndex]); gap lines (ending on an opponent move) get
/// "[titlePrefix] — no answer to 6...Bg4 yet" plus [kGapLineComment] on the
/// final move, so unfinished prep is unmistakable in the list and on the
/// board.
String draftLinesToPgnGames(
  List<List<String>> lines, {
  required bool isWhite,
  required String titlePrefix,
  int startIndex = 0,
}) {
  final buffer = StringBuffer();
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final moveText = MoveTree.fromMoves(line).toPgnMoveText();
    if (moveText.isEmpty) continue;

    final isGap = !lineEndsWithMyMove(line, isWhite: isWhite);
    final title = isGap
        ? '$titlePrefix — no answer to ${lastMoveLabel(line)} yet'
        : '$titlePrefix — line ${startIndex + i + 1}';
    final movetext = isGap ? '$moveText { $kGapLineComment } *' : '$moveText *';
    buffer
      ..writeln('[Event "$title"]')
      ..writeln('[White "${isWhite ? 'Me' : 'Opponent'}"]')
      ..writeln('[Black "${isWhite ? 'Opponent' : 'Me'}"]')
      ..writeln('[Result "*"]')
      ..writeln()
      ..writeln(movetext)
      ..writeln();
  }
  return buffer.toString();
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
    ..writeln()
    ..write(
      draftLinesToPgnGames(
        enumerateLines(tree),
        isWhite: isWhite,
        titlePrefix: name,
      ),
    );

  return buffer.toString();
}

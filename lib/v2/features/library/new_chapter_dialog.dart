import 'package:flutter/material.dart';

import '../../chess/fen.dart';
import '../../chess/pgn/chapter.dart';
import '../../chess/pgn/chapter_heading.dart';
import '../../chess/pgn/game_tree.dart';
import '../../ui/name_dialog.dart';
import '../../ui/theme.dart';

/// What the user asked for: a name, and the moves the chapter starts after,
/// empty for a chapter that starts at the start.
typedef NewChapter = ({String name, List<String> rootMoves});

/// The moves from the initial position to the board's position in
/// [chapter], or null when there is no such line to offer: the board is at
/// the start, or the chapter starts from a position no move list reaches.
///
/// A chapter's own root is its `// Root:` line; a chapter that starts from a
/// bare `[FEN]` with no such line has a position but no moves to it, and a
/// new chapter made from there would have the same problem.
List<String>? rootMovesFromBoard(Chapter chapter, NodePath cursor) {
  final tree = chapter.tree;
  final heading = readHeading(chapter.preamble);
  final List<String> toRoot;
  if (tree.rootFen == Fen.initial) {
    toRoot = const [];
  } else if (heading.rootFen == tree.rootFen) {
    toRoot = heading.rootMoves;
  } else {
    return null;
  }
  final line = [for (final node in tree.lineTo(cursor)) node.san];
  final moves = [...toRoot, ...line];
  return moves.isEmpty ? null : moves;
}

/// Asks for a new chapter, or answers null when the user backed out.
///
/// With [fromBoard] given, the user chooses whether the chapter starts at
/// the start or after those moves, which is how a chapter for the King's
/// Gambit is made: play 1. e4 e5 2. f4, ask for a chapter, keep "From here".
Future<NewChapter?> showNewChapterDialog(
  BuildContext context, {
  List<String>? fromBoard,
}) async {
  var fromHere = fromBoard != null;
  final name = await showNameDialog(
    context,
    title: 'New chapter',
    label: 'Chapter name',
    hint: fromBoard == null ? null : "King's Gambit",
    confirm: 'Create',
    extra: fromBoard == null
        ? null
        : (context, changed) => _StartPicker(
            moves: ChapterHeading(rootMoves: fromBoard).rootText,
            fromHere: fromHere,
            onChanged: (chosen) {
              fromHere = chosen;
              changed();
            },
          ),
  );
  if (name == null) return null;
  return (name: name, rootMoves: fromHere ? fromBoard! : const <String>[]);
}

class _StartPicker extends StatelessWidget {
  const _StartPicker({
    required this.moves,
    required this.fromHere,
    required this.onChanged,
  });

  /// The board's line, as the chapter would print it.
  final String moves;

  final bool fromHere;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Starts', style: theme.textTheme.labelSmall),
        const SizedBox(height: Space.xs),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: true, label: Text('From here')),
            ButtonSegment(value: false, label: Text('From the start')),
          ],
          selected: {fromHere},
          onSelectionChanged: (chosen) => onChanged(chosen.first),
        ),
        if (fromHere) ...[
          const SizedBox(height: Space.s),
          Text(
            moves,
            style: monoText.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}

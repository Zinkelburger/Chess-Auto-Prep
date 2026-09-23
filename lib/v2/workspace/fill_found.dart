import 'package:dartchess/dartchess.dart' show Side;

import '../chess/fen.dart';
import '../chess/generation/draft_lines.dart';
import '../chess/generation/search_node.dart' show MoveRef;
import '../chess/generation/traps.dart';
import '../storage/chapter_files.dart';

/// Where the results of a run can be read.
sealed class FillOrigin {
  const FillOrigin();
}

/// A run on the analysis board: the board's root and the moves from it to
/// where the search started. A result is shown by playing it there.
final class OnTheBoard extends FillOrigin {
  const OnTheBoard({required this.root, required this.line});

  final Fen root;
  final List<MoveRef> line;
}

/// A run on a chapter: the draft it wrote, and the moves from the draft's
/// root to where the search started. A result is shown by opening the
/// draft there.
final class InDraft extends FillOrigin {
  const InDraft({required this.draft, required this.sans});

  final ChapterRef draft;
  final List<String> sans;
}

/// One thing a run found worth looking at: a trap or a line.
sealed class FoundItem {
  const FoundItem();

  /// The moves from where the search started.
  List<DraftMove> get moves;

  /// How many of [moves] to play before stopping on the board: a trap stops
  /// on the blunder, so the punishment is the user's to find.
  int get stopAfter;
}

final class FoundTrap extends FoundItem {
  const FoundTrap(this.trap);

  final Trap trap;

  @override
  List<DraftMove> get moves => trap.moves;

  @override
  int get stopAfter => trap.toTrap.length + 1;
}

final class FoundLine extends FoundItem {
  const FoundLine(this.line);

  final DraftLine line;

  @override
  List<DraftMove> get moves => line.moves;

  @override
  int get stopAfter => line.moves.length;
}

/// What the last finished run found, kept until the next one starts: its
/// traps, best first, then its lines, most reached first.
final class FillFound {
  const FillFound({
    required this.origin,
    required this.side,
    required this.traps,
    required this.lines,
  });

  final FillOrigin origin;

  /// The side the search played for.
  final Side side;
  final List<Trap> traps;
  final List<DraftLine> lines;

  /// The traps and then the lines, in the order the Prep tab lists them.
  List<FoundItem> get items => [
    for (final trap in traps) FoundTrap(trap),
    for (final line in lines) FoundLine(line),
  ];
}

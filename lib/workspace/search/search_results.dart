import 'dart:async';

import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';

import '../../chess/generation/search_node.dart';
import '../../storage/chapter_files.dart';
import '../../ui/theme.dart';
import '../document/document_session.dart';
import 'fill_gaps.dart';
import 'fill_states.dart';
import 'search_table.dart';

/// The Expectimax panel's results for the position on the board: the
/// table of moves the search looked at, or one sentence saying why there
/// is none here.
class SearchResults extends StatelessWidget {
  const SearchResults({
    super.key,
    required this.fill,
    required this.session,
    required this.book,
    required this.onHover,
    required this.onLeave,
    required this.onPlay,
  });

  final FillGaps fill;
  final DocumentSession session;

  /// The search builds a mainline book (`Build`) rather than running
  /// expectimax.
  final bool book;

  final void Function(SearchRow row, Offset anchor) onHover;
  final VoidCallback onLeave;
  final ValueChanged<SearchRow> onPlay;

  String get _run => book ? 'Build' : 'Expectimax';

  @override
  Widget build(BuildContext context) {
    final found = fill.found;
    if (found == null) {
      return _sentence(
        context,
        fill.running
            ? 'Evaluating the first moves…'
            : 'Press ▶ $_run to evaluate moves from this position.',
      );
    }
    final side = session.orientation;
    final both = found.request.mirrored;
    final mine = fill.nodeAtBoard(request: found.request);
    final other = both
        ? fill.nodeAtBoard(request: found.request, side: side.opposite)
        : null;
    final rows = searchRows(side: side, mine: mine, other: other);
    if (rows.isNotEmpty) {
      return SearchTable(
        rows: rows,
        ours: session.cursor.fen.whiteToMove == (side == Side.white),
        sides: both ? const [Side.white, Side.black] : [side],
        valueTip: found.request.method == SearchMethod.mainline
            ? null
            : searchValueTip(side),
        engineDepthAt: fill.engineDepthAt,
        shareTip: (from) => repliesFromTip(
          from,
          database: found.request.replies.label,
          elo: found.request.elo,
          fallbackUnder: found.request.fallbackUnder,
        ),
        onHover: onHover,
        onLeave: onLeave,
        onPlay: onPlay,
      );
    }
    return switch (mine ?? other) {
      null => _offTree(context, found),
      TerminalNode() => _sentence(context, 'The game is over here.'),
      _ => _sentence(
        context,
        fill.running
            ? 'Not reached yet.'
            : 'The search stopped before this position.',
      ),
    };
  }

  Widget _offTree(BuildContext context, FillFound found) {
    final tree = session.tree;
    // A search made with other settings covers the board: its values are
    // not shown beside these settings', and the pane says why it is empty.
    final otherSettings = fill.nodeAtBoard() != null;
    final start = found.target.cursor;
    final canGo =
        tree != null &&
        tree.rootFen == found.target.rootFen &&
        _sameLine([
          for (final move in tree.lineTo(start)) move.san,
        ], found.target.sans);
    return Padding(
      padding: const EdgeInsets.all(Space.m),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            otherSettings
                ? 'The results here are from a search with other settings. '
                      '$_run searches again with these.'
                : 'No saved results here yet. Start $_run from this board.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (canGo) ...[
            const SizedBox(height: Space.s),
            OutlinedButton(
              onPressed: () => session.cursor.goTo(start),
              child: const Text('Go to where it started'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _sentence(BuildContext context, String words) => Padding(
    padding: const EdgeInsets.all(Space.m),
    child: Text(words, style: Theme.of(context).textTheme.bodySmall),
  );
}

/// Under a finished search on a repertoire chapter: the way to turn it
/// into lines, or what became of that. Nothing when neither applies.
class SearchLinesRow extends StatelessWidget {
  const SearchLinesRow({super.key, required this.fill, this.onOpenChapter});

  final FillGaps fill;

  /// Opens the draft the lines were written to.
  final ValueChanged<ChapterRef>? onOpenChapter;

  /// Whether [fill] has a lines row to show.
  static bool shows(FillGaps fill) =>
      fill.lines is LinesWritten ||
      fill.canMakeLines ||
      fill.lines is LinesWriting;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lines = fill.lines;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.m,
          vertical: Space.s,
        ),
        child: lines is LinesWritten
            ? _written(theme, lines)
            : _makeLines(theme, lines),
      ),
    );
  }

  Widget _written(ThemeData theme, LinesWritten lines) {
    final open = onOpenChapter;
    final count = lines.lines == 1 ? '1 line' : '${lines.lines} lines';
    return Row(
      children: [
        Expanded(
          child: Text(
            '$count in ${lines.draft.name}',
            style: theme.textTheme.bodySmall,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (open != null)
          OutlinedButton(
            onPressed: () => open(lines.draft),
            child: const Text('Open'),
          ),
      ],
    );
  }

  Widget _makeLines(ThemeData theme, LinesState? lines) => Row(
    children: [
      Expanded(
        child: lines is LinesFailed
            ? Tooltip(
                message: lines.reason,
                child: Text(
                  lines.reason,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              )
            : const SizedBox.shrink(),
      ),
      Tooltip(
        message:
            'Write the best moves as lines in a draft chapter beside '
            'this one, traps marked ?',
        child: OutlinedButton(
          onPressed: fill.canMakeLines
              ? () => unawaited(fill.makeLines())
              : null,
          child: const Text('Make lines'),
        ),
      ),
    ],
  );
}

bool _sameLine(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

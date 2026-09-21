import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';

import '../chess/pgn/chapter.dart';
import '../chess/pgn/game_summary.dart';
import '../ui/theme.dart';
import 'chapter_commands.dart';
import 'document_session.dart';

/// What is open, the way a book heads a game: the name centred, and under
/// it who played it and where, or how much of the file a merged chapter
/// holds. A repertoire chapter also shows the side it is played from, which
/// is the one thing here that can be changed.
///
/// Nothing about saving is said here. Reading a file is not editing it, and
/// the save state belongs to the edit strip that appears when editing does.
class ReadingHeader extends StatelessWidget {
  const ReadingHeader({super.key, required this.session});

  final DocumentSession session;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final chapter = session.chapter;
        if (chapter == null) {
          return Padding(
            padding: const EdgeInsets.all(Space.m),
            child: Text(
              'Open a chapter',
              style: text.bodySmall,
              textAlign: TextAlign.center,
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            Space.m,
            Space.m,
            Space.m,
            Space.s,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _title(chapter),
                style: text.titleMedium,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: Space.xs),
              _SideAndSummary(
                chapter: chapter,
                onSide: (side) => setSide(session, side),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// A viewed game is headed by its players or its event; a chapter by its
/// name.
String _title(Chapter chapter) {
  final index = chapter.game;
  if (index == null || index >= chapter.lines.length) return chapter.name;
  return summarizeGame(chapter.lines[index], index: index).title;
}

class _SideAndSummary extends StatelessWidget {
  const _SideAndSummary({required this.chapter, required this.onSide});

  final Chapter chapter;
  final ValueChanged<Side> onSide;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      // A study chapter's board faces the way its own `[Orientation]` tag
      // says, which its row in the study list changes; the `// Color:` line
      // these buttons write belongs to a repertoire chapter and is not what
      // a study reads.
      if (chapter.game == null)
        _SideChoice(side: chapter.side, onChanged: onSide),
      if (chapter.game == null) const SizedBox(width: Space.s),
      Flexible(
        child: Text(
          _summary(chapter),
          style: Theme.of(context).textTheme.bodySmall,
          textAlign: TextAlign.center,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ],
  );
}

/// Which side the chapter is played from, and the way to change it. It is
/// two things, so it is two buttons: the answer is always in front of the
/// user rather than behind a menu they have to open to read it.
class _SideChoice extends StatelessWidget {
  const _SideChoice({required this.side, required this.onChanged});

  final Side side;
  final ValueChanged<Side> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<Side>(
      segments: const [
        ButtonSegment(value: Side.white, label: Text('White')),
        ButtonSegment(value: Side.black, label: Text('Black')),
      ],
      selected: {side},
      showSelectedIcon: false,
      style: const ButtonStyle(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onSelectionChanged: (chosen) => onChanged(chosen.first),
    );
  }
}

/// What the line under the name says: for one game of a file, its result
/// and where it was played; for a merged chapter, how much of the file it
/// holds.
String _summary(Chapter chapter) =>
    chapter.game == null ? _lineCount(chapter) : _gameLine(chapter);

/// The result and the event of the game on the board. Empty parts are left
/// out rather than written as `?`.
String _gameLine(Chapter chapter) {
  final index = chapter.game!;
  if (index >= chapter.lines.length) return '';
  final game = summarizeGame(chapter.lines[index], index: index);
  return [
    if (game.result.isNotEmpty) game.result,
    if (game.setting.isNotEmpty) game.setting,
  ].join(' · ');
}

/// How many games of the file the chapter holds: the games merged into the
/// tree, then the ones left out and why, because a chapter that shows fewer
/// lines than the file has must say so.
String _lineCount(Chapter chapter) {
  final lines = chapter.gameCount == 1
      ? '1 line'
      : '${chapter.gameCount} lines';
  final skipped = chapter.skippedGames == 0
      ? ''
      : ', ${chapter.skippedGames} from another position';
  final unreadable = chapter.unreadableGames == 0
      ? ''
      : ', ${chapter.unreadableGames} could not be read';
  // A line this app will not write is one the user should hear about before
  // they try to edit it, not after the edit is refused.
  final protected = chapter.protectedGames == 0
      ? ''
      : ', ${chapter.protectedGames} cannot be edited here';
  return '$lines$skipped$unreadable$protected';
}

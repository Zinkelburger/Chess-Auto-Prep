import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';

import '../chess/pgn/chapter.dart';
import '../chess/pgn/game_summary.dart';
import '../ui/theme.dart';
import 'document_session.dart';

/// What is open, the way a book heads a game: the name centred, and under
/// it who played it and where, or how much of the file a merged chapter
/// holds and which side it is played from. The side is written, not
/// switched: it is asked once, when a file does not say, and changed from
/// the Actions menu after that.
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
            padding: const EdgeInsets.all(readingCardInset),
            child: Text(
              'Open a chapter',
              style: text.bodySmall,
              textAlign: TextAlign.center,
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            readingCardInset,
            readingCardInset,
            readingCardInset,
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
              Text(
                _summary(chapter),
                style: text.bodySmall,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
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

/// What the line under the name says: for one game of a file, its result
/// and where it was played; for a merged chapter, the side it is played
/// from and how much of the file it holds.
String _summary(Chapter chapter) => chapter.game == null
    ? '${chapter.side == Side.white ? 'White' : 'Black'} · ${_lineCount(chapter)}'
    : _gameLine(chapter);

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

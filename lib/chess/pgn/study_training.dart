import 'package:dartchess/dartchess.dart' show Side;

import 'chapter.dart';
import 'chapter_edit.dart';
import 'chapter_line.dart';
import 'game_text.dart';
import 'games_written.dart';
import 'rewrite_gate.dart';

/// One undoable edit for the chapter sides explicitly chosen by the player.
/// Board orientation and untouched chapters keep their original values.
ChapterEdit setStudyTrainingSides(Chapter chapter, Map<int, Side> sides) {
  final lines = [...chapter.lines];
  final changed = <int>{};
  for (final entry in sides.entries) {
    final index = entry.key;
    if (index < 0 || index >= lines.length) {
      return const ChapterEditRefused(
        'The study changed. Choose the sides again.',
      );
    }
    final line = lines[index];
    if (!line.isWhole) {
      return ChapterEditRefused(
        'Chapter ${index + 1} could not be read completely. Its text is unchanged.',
      );
    }
    final value = entry.value == Side.white ? 'white' : 'black';
    if (tagValue(line.tags, 'TrainingSide') == value) continue;
    final tags = [
      for (final tag in line.tags)
        if (tag is! PgnTag || tag.key != 'TrainingSide') tag,
      PgnTag(
        'TrainingSide',
        value,
        trailer: line.tags.firstOrNull?.trailer ?? '\n',
      ),
    ];
    final next = ChapterLine(
      tags: tags,
      tree: line.tree,
      text: line.text,
      trailer: line.trailer,
      terminator: line.terminator,
      separator: line.separator,
    );
    final result = rewritten(next, line.tree!);
    if (result case LineRefused(:final reason))
      return ChapterEditRefused(reason);
    lines[index] = (result as LineRewritten).line;
    changed.add(index);
  }
  if (changed.isEmpty) return const ChapterUnchanged();
  return ChapterEdited(
    withLines(chapter, lines),
    GamesArranged.of(GamesWritten(rewritten: changed), before: lines.length),
  );
}

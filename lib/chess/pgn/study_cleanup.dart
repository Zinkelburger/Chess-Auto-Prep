import 'package:dartchess/dartchess.dart' show Chess, Setup;

import '../fen.dart';
import 'chapter.dart';
import 'chapter_edit.dart';
import 'chapter_line.dart';
import 'game_text.dart';
import 'game_tree.dart';
import 'games_written.dart';
import 'rewrite_gate.dart';
import 'study.dart';

ChapterEdit editStudyTags(
  Chapter chapter,
  int index,
  Map<String, String> values,
) {
  for (final key in values.keys) {
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9_]*$').hasMatch(key))
      return ChapterEditRefused('Invalid tag name: $key.');
    if (studyOwnedTags.contains(key))
      return ChapterEditRefused('$key belongs to the study.');
  }
  final result = values['Result'];
  if (result != null && !{'*', '1-0', '0-1', '1/2-1/2'}.contains(result))
    return const ChapterEditRefused(
      'Use a PGN result: *, 1-0, 0-1 or 1/2-1/2.',
    );
  return _edit(chapter, index, (line, tree) {
    final remaining = {...values};
    final tags = <PgnHeader>[];
    for (final tag in line.tags) {
      if (tag is! PgnTag || studyOwnedTags.contains(tag.key)) {
        tags.add(tag);
        continue;
      }
      final value = remaining.remove(tag.key);
      if (value != null)
        tags.add(
          value == tag.value
              ? tag
              : PgnTag(tag.key, value, trailer: tag.trailer),
        );
    }
    final ending = line.tags.firstOrNull?.trailer ?? '\n';
    tags.addAll(
      remaining.entries.map((e) => PgnTag(e.key, e.value, trailer: ending)),
    );
    return (tags: tags, tree: tree, result: result ?? line.terminator);
  });
}

ChapterEdit resetStudyChapter(Chapter chapter, int index, Fen root) {
  try {
    Chess.fromSetup(Setup.parseFen(root.value));
  } on Object {
    return const ChapterEditRefused('Use a legal starting FEN.');
  }
  final study = studyNameIn(chapter.lines) ?? chapter.name;
  return _edit(chapter, index, (line, tree) {
    final tags = withStudyTags(
      [
        for (final tag in line.tags)
          if (tag is! PgnTag || !{'FEN', 'SetUp', 'Result'}.contains(tag.key))
            tag,
        const PgnTag('Result', '*'),
      ],
      study: study,
      chapter: studyChapterName(line, index: index, study: study),
      orientation: studyOrientation(line),
      root: root,
    );
    return (
      tags: tags,
      tree: GameTree(rootFen: root, rootComment: tree.rootComment),
      result: '*',
    );
  });
}

ChapterEdit cleanStudyChapter(
  Chapter chapter,
  int index, {
  required bool annotations,
}) => _edit(
  chapter,
  index,
  (line, tree) => (
    tags: line.tags,
    tree: annotations ? _withoutAnnotations(tree) : _mainline(tree),
    result: line.terminator,
  ),
);

typedef _Replacement = ({List<PgnHeader> tags, GameTree tree, String? result});
ChapterEdit _edit(
  Chapter chapter,
  int index,
  _Replacement Function(ChapterLine, GameTree) change,
) {
  if (index < 0 || index >= chapter.lines.length)
    return const ChapterEditRefused('That chapter is no longer in the study.');
  final line = chapter.lines[index];
  if (!line.isWhole)
    return const ChapterEditRefused(
      'That chapter was not read whole, so it keeps its original text.',
    );
  final next = change(line, line.tree!);
  final updated = ChapterLine(
    tags: next.tags,
    tree: next.tree,
    text: line.text,
    trailer: line.trailer,
    terminator: next.result,
    separator: line.separator,
  );
  final written = rewritten(updated, next.tree);
  if (written case LineRefused(:final reason))
    return ChapterEditRefused(reason);
  final lines = [...chapter.lines];
  lines[index] = (written as LineRewritten).line;
  return ChapterEdited(
    withLines(chapter, lines),
    GamesArranged.of(GamesWritten(rewritten: {index}), before: lines.length),
  );
}

GameTree _mainline(GameTree tree) {
  final moves = <MoveNode>[];
  var node = tree.children.firstOrNull;
  while (node != null) {
    moves.add(node);
    node = node.children.firstOrNull;
  }
  var children = <MoveNode>[];
  for (final move in moves.reversed) {
    children = [move.copyWith(children: children)];
  }
  return GameTree(
    rootFen: tree.rootFen,
    rootComment: tree.rootComment,
    children: children,
  );
}

GameTree _withoutAnnotations(GameTree tree) {
  final made = <MoveNode, MoveNode>{};
  final pending = [for (final node in tree.children) (node, false)];
  while (pending.isNotEmpty) {
    final (node, visited) = pending.removeLast();
    if (!visited) {
      pending.add((node, true));
      pending.addAll(node.children.map((n) => (n, false)));
      continue;
    }
    made[node] = MoveNode(
      san: node.san,
      uci: node.uci,
      fen: node.fen,
      spelling: node.spelling,
      children: [for (final child in node.children) made[child]!],
    );
  }
  return GameTree(
    rootFen: tree.rootFen,
    children: [for (final node in tree.children) made[node]!],
  );
}

({int moves, int comments, int sidelines}) studyContentCount(GameTree tree) {
  var moves = 0, comments = tree.rootComment == null ? 0 : 1, main = 0;
  final pending = [...tree.children];
  while (pending.isNotEmpty) {
    final node = pending.removeLast();
    moves++;
    if (node.comment != null) comments++;
    if (node.startingComment != null) comments++;
    pending.addAll(node.children);
  }
  var node = tree.children.firstOrNull;
  while (node != null) {
    main++;
    node = node.children.firstOrNull;
  }
  return (moves: moves, comments: comments, sidelines: moves - main);
}

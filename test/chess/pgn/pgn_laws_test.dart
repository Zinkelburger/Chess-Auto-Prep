/// The core laws of reading and writing a chapter file, over generated
/// chapters that carry what they mean and over the same chapters damaged.
///
/// P1 byte identity, P2 a one-step fixpoint with the tree unchanged, P3
/// headers kept, P5 every node a legal move from its parent and nothing read
/// past an illegal one, P10 no input throws. `CAP_PROP_RUNS` (200 by
/// default) and `CAP_PROP_SEED` soak or replay any of them.
library;

import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/pgn/chapter_line.dart';
import 'package:chess_auto_prep/chess/pgn/chapter_sections.dart';
import 'package:chess_auto_prep/chess/pgn/game_text.dart';
import 'package:chess_auto_prep/chess/pgn/pgn_issue.dart';
import 'package:chess_auto_prep/chess/pgn/pgn_reader.dart';
import 'package:chess_auto_prep/chess/pgn/rewrite_gate.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/gen/pgn_gen.dart';
import '../../support/gen/pgn_mutations.dart';
import '../../support/gen/tree_gen.dart';
import '../../support/pgn_round_trip.dart';
import '../../support/props.dart';

/// A generated chapter, damaged by one to three mutations.
typedef Damaged = ({String text, List<String> applied});

final Generator<Damaged> damagedChapters = Generator(
  (r) => mutate(renderChapter(chapterSpecs().sample(r)).text, r),
);

Chapter _parsed(String text) => parseChapter(name: 'Laws', text: text);

void main() {
  forAll(
    'the generator: every game reads back as what it meant',
    chapterSpecs(),
    (spec) {
      final rendered = renderChapter(spec);
      final chapter = _parsed(rendered.text);
      expect(chapter.preamble, rendered.preamble, reason: 'preamble');
      expect(chapter.lines, hasLength(rendered.games.length), reason: 'games');
      for (final (index, truth) in rendered.games.indexed) {
        _expectTruth(chapter.lines[index], truth, 'game $index');
      }
    },
  );

  group('P1 a chapter read and written again is the same bytes', () {
    forAll('generated', chapterSpecs(), (spec) {
      final text = renderChapter(spec).text;
      expect(writeChapter(_parsed(text)), text);
    });
    forAll('damaged', damagedChapters, (damaged) {
      expect(writeChapter(_parsed(damaged.text)), damaged.text);
    });
  });

  group('P2 every whole game is rewritten once and for all', () {
    forAll('generated', chapterSpecs(), (spec) {
      _expectFixpoints(_parsed(renderChapter(spec).text));
    });
    forAll('damaged', damagedChapters, (damaged) {
      _expectFixpoints(_parsed(damaged.text));
    });
  });

  group('P3 a rewritten game keeps every header line', () {
    forAll('generated', chapterSpecs(), (spec) {
      _expectHeadersKept(_parsed(renderChapter(spec).text));
    });
    forAll('damaged', damagedChapters, (damaged) {
      _expectHeadersKept(_parsed(damaged.text));
    });
  });

  group('P5 every move read is legal where it stands', () {
    forAll('generated, nothing read past an illegal move', chapterSpecs(), (
      spec,
    ) {
      final rendered = renderChapter(spec);
      final chapter = _parsed(rendered.text);
      for (final (index, truth) in rendered.games.indexed) {
        final line = chapter.lines[index];
        _expectLegal(line, 'game $index');
        expect(
          treeDifference(line.tree!, truth.tree),
          isNull,
          reason: 'game $index',
        );
        expect(
          line.issues.whereType<IllegalMove>(),
          hasLength(truth.illegal ? 1 : 0),
          reason: 'game $index: ${line.issues}',
        );
      }
    });
    forAll('damaged', damagedChapters, (damaged) {
      for (final (index, line) in _parsed(damaged.text).lines.indexed) {
        _expectLegal(line, 'game $index');
      }
    });
  });

  forAll(
    'P10 no damaged chapter makes reading or writing throw',
    damagedChapters,
    (damaged) {
      final chapter = _parsed(damaged.text);
      writeChapter(chapter);
      for (final line in chapter.lines) {
        final read = readGame(line.text);
        final tree = read.tree;
        if (tree == null) continue;
        rewritten(line, tree);
        written(read);
      }
    },
  );
}

void _expectTruth(ChapterLine line, GameTruth truth, String game) {
  expect(line.isWhole, truth.whole, reason: '$game whole: ${line.issues}');
  expect(line.tree, isNotNull, reason: game);
  expect(treeDifference(line.tree!, truth.tree), isNull, reason: game);
  expect(_headerLines(line.tags), truth.headers, reason: '$game headers');
  expect(line.terminator, truth.terminator, reason: '$game terminator');
  expect(line.separator, truth.separator, reason: '$game separator');
  expect(sectionOf(line), truth.section, reason: '$game section');
  expect(line.lineId, truth.lineId, reason: '$game line id');
}

List<({String text, String trailer})> _headerLines(List<PgnHeader> tags) => [
  for (final tag in tags) (text: tag.text, trailer: tag.trailer),
];

/// P2: the gate takes every whole game with its own tree; the text it
/// writes reads back with no issue as the same tree, and writing that
/// again changes nothing.
void _expectFixpoints(Chapter chapter) {
  for (final (index, line) in chapter.lines.indexed) {
    if (!line.isWhole) continue;
    final game = 'game $index:\n${line.text}';
    final rewrite = rewritten(line, line.tree!);
    if (rewrite is LineRefused) fail('$game\nrefused: ${rewrite.reason}');
    final text = (rewrite as LineRewritten).line.text;
    final read = readGame(text);
    expect(read.issues, isEmpty, reason: '$game\nwritten as\n$text');
    expect(treeDifference(read.tree!, line.tree!), isNull, reason: game);
    expect(read.terminator, line.terminator, reason: game);
    expect(written(read), text, reason: '$game\nwritten as\n$text');
    final again = rewritten(lineOf(read, text), read.tree!);
    expect((again as LineRewritten).line.text, text, reason: game);
  }
}

/// P3: a whole game written again keeps its header lines exactly — text,
/// what followed each, order, duplicates and lines that are not tags.
void _expectHeadersKept(Chapter chapter) {
  for (final (index, line) in chapter.lines.indexed) {
    if (!line.isWhole) continue;
    final rewrite = rewritten(line, line.tree!);
    if (rewrite is! LineRewritten) continue;
    final read = readGame(rewrite.line.text);
    expect(
      _headerLines(read.tags),
      _headerLines(line.tags),
      reason: 'game $index:\n${line.text}',
    );
    expect(
      [for (final tag in read.tags.whereType<PgnTag>()) (tag.key, tag.value)],
      [for (final tag in line.tags.whereType<PgnTag>()) (tag.key, tag.value)],
      reason: 'game $index',
    );
  }
}

/// P5: every node of [line] is its own move played from its parent.
void _expectLegal(ChapterLine line, String game) {
  final tree = line.tree;
  if (tree == null) return;
  for (final (parent, node) in nodesWithParents(tree)) {
    expect(illegalStep(parent, node), isNull, reason: '$game:\n${line.text}');
  }
}

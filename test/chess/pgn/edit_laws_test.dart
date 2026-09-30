/// Laws every chapter edit keeps, over generated files and edits made
/// through the app's own edits and landed as the workspace lands them.
///
/// P4 a game reading could not take whole keeps its unread text, and leaves
/// the file only when the edit is one that takes games out; P8 a line an edit
/// keeps keeps the id it is trained under, and a new line takes no id the
/// file already knows; P11 a review annotated and then removed leaves the
/// user's moves and notes. Beside them: a note edit leaves the notes the
/// user never saw, a fold keeps every move of the line folded in, and a
/// course pins every line's id. A typed refusal is an answer, not a failure.
/// `CAP_PROP_RUNS` (200 by default) and `CAP_PROP_SEED` soak or replay any
/// of them. The scope law, P6, is in `test/storage/edit_scope_laws_test`.
library;

import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/pgn/chapter_line.dart';
import 'package:chess_auto_prep/chess/pgn/comment_text.dart';
import 'package:chess_auto_prep/chess/pgn/game_text.dart';
import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/chess/pgn/line_id_pins.dart';
import 'package:chess_auto_prep/chess/pgn/tree_edit.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/gen/edit_gen.dart';
import '../../support/gen/pgn_gen.dart';
import '../../support/props.dart';

/// Game C's `[LineID "x"]` is shadowed by B's, so C is trained under an id
/// worked out from its place.
const _duplicateIds = LiteralFile(
  '[Event "A"]\n\n1. d4 *\n\n'
  '[Event "B"]\n[LineID "x"]\n\n1. e4 *\n\n'
  '[Event "C"]\n[LineID "x"]\n\n1. c4 *\n',
);

/// Game A carries B's `[LineID "x"]` and no moves, so B is trained under it
/// until A has a move. B starts somewhere else, so a first move goes into A.
const _headerOnly = LiteralFile(
  '[Event "A"]\n[LineID "x"]\n\n*\n\n'
  '[Event "B"]\n[LineID "x"]\n[FEN "4k3/8/8/8/8/8/8/4K2R w K - 0 1"]\n\n'
  '1. Rh2 *\n',
);

/// Game B's empty `[LineID ""]` gives it no id, so it is trained under one
/// worked out from its place.
const _emptyId = LiteralFile(
  '[Event "A"]\n\n1. d4 *\n\n'
  '[Event "B"]\n[LineID ""]\n\n1. g4 *\n',
);

void main() {
  test('the generator reaches every edit, refusal and awkward file', () {
    final seen = _Tally();
    for (var seed = 0; seed < 400; seed++) {
      seen.add(editCases.sample(Rand(defaultPropSeed + seed)));
      seen.add(_reviewCases.sample(Rand(defaultPropSeed + seed)));
    }
    expect(seen.landed.keys, containsAll(EditKind.values), reason: '$seen');
    expect(seen.refused, isNotEmpty, reason: '$seen');
    expect(seen.courses, greaterThan(20), reason: '$seen');
    expect(seen.notWhole, greaterThan(20), reason: '$seen');
    expect(seen.sharedIds, greaterThan(20), reason: '$seen');
  });

  forAll(
    'P4 a game not read whole keeps its unread text',
    editCases,
    (c) => runEdits(c).forEach(_expectUnreadKept),
    regressions: confirmedCases,
  );

  forAll(
    'P8 a kept line keeps its id, a new line takes none in use',
    editCases,
    (c) => runEdits(c).forEach(_expectIdsKept),
    regressions: confirmedCases,
  );

  test('P8 two lines with one id header keep their ids', () {
    _expectKeepsIds(_duplicateIds, const EditSpec(EditKind.deleteLine));
    _expectKeepsIds(_headerOnly, const EditSpec(EditKind.addMove));
  });

  test(
    'P8 a line with an empty id header keeps its id',
    () => _expectKeepsIds(_emptyId, const EditSpec(EditKind.deleteLine)),
  );

  forAll(
    'a note edit leaves the notes the user never saw',
    editCases,
    (c) => runEdits(c).forEach(_expectUnseenNotesKept),
    regressions: confirmedCases,
  );

  forAll(
    'a fold keeps every move of the line folded in',
    editCases,
    (c) => runEdits(c).forEach(_expectFoldKept),
    regressions: confirmedCases,
  );

  forAll(
    'P11 a review annotated then removed leaves the user its moves and notes',
    _reviewCases,
    _expectReviewUndone,
    regressions: [reviewOverUserMoves],
  );

  forAll(
    'a course carries the id each of its lines is trained under',
    _courses,
    _expectCoursePinned,
    regressions: [sharedSourceIds],
  );
}

// ---------------------------------------------------------------------------
// P4
// ---------------------------------------------------------------------------

/// A game not read whole that the edit kept is at its new place with its
/// movetext unchanged; only its `[LineID]` or `[ChapterName]` may differ.
/// One the edit dropped was dropped by an edit that takes games out, and
/// never by a fold.
void _expectUnreadKept(EditStep step) {
  final after = step.after;
  if (after == null) return;
  final before = wholeFile(step.before);
  final now = wholeFile(after);
  final games = (step.outcome as EditLanded).games;
  final kept = games.order.nonNulls.toSet();
  for (final (index, line) in before.lines.indexed) {
    if (line.isWhole) continue;
    final reason = '${step.spec}: game $index\n${line.text}';
    if (!kept.contains(index)) {
      expect(removingKinds, contains(step.spec.kind), reason: reason);
      expect(step.fold?.arriving, isNot(index), reason: 'folded $reason');
      continue;
    }
    final moved = now.lines[games.order.indexOf(index)];
    expect(movesOf(moved), movesOf(line), reason: reason);
    expect(_ownTags(moved), _ownTags(line), reason: reason);
  }
}

const _idOrSection = {..._idKeys, 'ChapterName'};

List<String> _ownTags(ChapterLine line) => [
  for (final header in line.tags)
    if (header is! PgnTag || !_idOrSection.contains(header.key)) header.text,
];

// ---------------------------------------------------------------------------
// P8
// ---------------------------------------------------------------------------

/// Every line the edit kept is trained under the id it was trained under,
/// and every line it made under one no game of the file was known by. A
/// game with no moves had no id; once it has moves it may be known by the
/// id they give it, but never by one a line the edit kept is trained under.
///
/// A study's games are not trained by id, and a game no id header both apps
/// read can be written into ([_unpinnable]) is not held to its id.
void _expectIdsKept(EditStep step) {
  final after = step.after;
  if (after == null || !step.trained) return;
  final before = wholeFile(step.before);
  final was = trainedIdsOf(before);
  final now = trainedIdsOf(wholeFile(after));
  final inUse = idsInUse(before);
  final games = (step.outcome as EditLanded).games;
  final kept = {for (final from in games.order.nonNulls) ?was[from]};
  for (final (place, from) in games.order.indexed) {
    final id = now[place];
    final reason = '${step.spec}: game $place from $from\n$after';
    if (from == null) {
      if (id != null) expect(inUse, isNot(contains(id)), reason: reason);
      continue;
    }
    final old = was[from];
    if (_unpinnable(before.lines[from])) continue;
    if (old == null) {
      if (id != null) expect(kept, isNot(contains(id)), reason: reason);
      continue;
    }
    expect(id, old, reason: reason);
  }
}

/// [spec] made to the whole of [file], every line keeping its id.
void _expectKeepsIds(LiteralFile file, EditSpec spec) => _expectIdsKept(
  makeEdit(shownOf(file.text, Focus.file, 0), file.text, spec),
);

/// Whether [line] can carry no id header both apps read. The old app ends a
/// game's header block at a tag it cannot match or a line that is not a
/// tag, and reads what follows as moves. An id header both apps read goes
/// above that line, so a game whose `[Event` line is one, or whose id
/// header this app reads is below one, can carry none, and the id both
/// apps train it under moves with it.
bool _unpinnable(ChapterLine line) =>
    _oldAppEndsHeaderEarly(line) && withIdHeader(line, 'probe') == null;

const _idKeys = {'LineID', 'LineId', 'Id', 'Line', 'Guid'};

/// Whether the old app ends [line]'s header block before this app does: at
/// a tag its pattern does not match, or at a line that is not a tag below
/// the first tag.
bool _oldAppEndsHeaderEarly(ChapterLine line) {
  final tag = RegExp(
    r'^\s*\[[A-Za-z0-9][A-Za-z0-9_+#=:-]*\s+"(?:[^"\\]|\\"|\\\\)*"\]$',
  );
  var started = false;
  for (final header in line.tags) {
    if (header is PgnTag) {
      if (!tag.hasMatch(header.text)) return true;
      started = true;
    } else if (started || !header.text.startsWith('%')) {
      return true;
    }
  }
  return false;
}

// ---------------------------------------------------------------------------
// Notes
// ---------------------------------------------------------------------------

/// A note edit on a move writes the games showing the note the user saw; a
/// game holding other words on that move keeps its bytes.
void _expectUnseenNotesKept(EditStep step) {
  final after = step.after;
  final sans = step.sans;
  final kinds = {EditKind.comment, EditKind.commentInReview};
  if (after == null || sans == null || sans.isEmpty) return;
  if (!kinds.contains(step.spec.kind) || !step.trained) return;
  final chapter = step.shown.chapter;
  final shown = chapter.tree.nodeAt(pathOfSans(chapter.tree, sans)!)!;
  final seen = displayComment(shown.comment ?? '');
  final games = (step.outcome as EditLanded).games;
  final now = wholeFile(after);
  for (final (index, line) in chapter.lines.indexed) {
    final note = _noteOn(chapter, line, sans);
    if (note == null || note == seen) continue;
    final place = step.shown.view?.places[index] ?? index;
    final moved = now.lines[games.order.indexOf(place)];
    expect(moved.text, line.text, reason: '${step.spec}: game $place');
  }
}

/// The words [line] holds on the move [sans] reaches, or null when it holds
/// none there or does not play it.
String? _noteOn(Chapter chapter, ChapterLine line, List<String> sans) {
  final tree = chapter.writableTree(line);
  final path = tree == null ? null : pathOfSans(tree, sans);
  final comment = path == null ? null : tree!.nodeAt(path)?.comment;
  return comment == null ? null : displayComment(comment);
}

// ---------------------------------------------------------------------------
// Folds
// ---------------------------------------------------------------------------

/// A line folded into another arrived whole and every move of it is in the
/// game it went into; one not read whole is refused.
void _expectFoldKept(EditStep step) {
  final fold = step.fold;
  if (fold == null) return;
  final before = wholeFile(step.before);
  final arriving = before.lines[fold.arriving];
  final after = step.after;
  if (!arriving.isWhole) {
    expect(step.outcome, isA<EditRefused>(), reason: '${step.spec}');
    return;
  }
  if (after == null) return;
  final games = (step.outcome as EditLanded).games;
  final host = wholeFile(after).lines[games.order.indexOf(fold.host)].tree!;
  for (final line in _lines(arriving.tree!.children)) {
    expect(pathOfSans(host, line), isNotNull, reason: '${step.spec}: $line');
  }
}

/// Every line from the root to a leaf of [nodes], as its moves.
List<List<String>> _lines(List<MoveNode> nodes) => [
  for (final node in nodes)
    if (node.children.isEmpty)
      [node.san]
    else
      for (final rest in _lines(node.children)) [node.san, ...rest],
];

// ---------------------------------------------------------------------------
// P11
// ---------------------------------------------------------------------------

/// One game, reviewed; then up to two edits of the user's inside the lines
/// the review added; then the review taken out.
final Generator<EditCase> _reviewCases = Generator(
  (r) => EditCase(
    GeneratedFile(chapterSpecs(maxGames: 1, maxPlies: 6).sample(r)),
    focus: Focus.game,
    edits: [
      sampleEdit(r, kinds: const [EditKind.annotate]),
      for (var i = r.between(0, 2); i > 0; i--)
        sampleEdit(
          r,
          kinds: const [EditKind.commentInReview, EditKind.moveInReview],
        ),
      const EditSpec(EditKind.removeReview),
    ],
  ),
  shrinker: shrunkCase,
);

/// The game after the review came out holds every move, note and glyph it
/// held before the review, and every move and note the user added in the
/// review's lines.
void _expectReviewUndone(EditCase c) {
  final steps = runEdits(c);
  final start = _gameTree(steps.first.before, c.pick);
  final end = _gameTree(steps.last.after ?? steps.last.before, c.pick);
  if (start == null || end == null) return;
  _expectHolds(end, start, 'the game before the review');
  for (final step in steps) {
    final sans = step.sans;
    if (step.after == null || sans == null) continue;
    final reason = '$step, then the review removed';
    final note = step.spec.kind == EditKind.commentInReview
        ? _lastNoteAt(steps, sans)
        : null;
    // A note cleared is nothing of the user's to keep.
    if (note == '') continue;
    final path = pathOfSans(end, sans);
    expect(path, isNotNull, reason: reason);
    if (note == null) continue;
    final kept = end.nodeAt(path!)!.comment ?? '';
    expect(displayComment(kept), note, reason: reason);
  }
}

GameTree? _gameTree(String text, int pick) {
  final lines = wholeFile(text).lines;
  return lines.isEmpty ? null : lines[pick % lines.length].tree;
}

/// The words the last of [steps] to write a note on [sans] wrote there.
String _lastNoteAt(List<EditStep> steps, List<String> sans) {
  final wrote = steps.lastWhere(
    (step) =>
        step.after != null &&
        step.spec.kind == EditKind.commentInReview &&
        step.sans?.join(' ') == sans.join(' '),
  );
  return displayComment(noteOf(wrote.spec));
}

/// Every node of [expected] is in [actual] at the same place with the same
/// notes, glyphs and moves after it, give or take added moves.
void _expectHolds(GameTree actual, GameTree expected, String what) {
  expect(_note(actual.rootComment), _note(expected.rootComment), reason: what);
  for (final path in nodePaths(expected)) {
    final want = expected.nodeAt(path)!;
    final sans = [for (final node in expected.lineTo(path)) node.san];
    final at = pathOfSans(actual, sans);
    expect(at, isNotNull, reason: '$what: $sans');
    final got = actual.nodeAt(at!)!;
    final reason = '$what: $sans';
    expect(_note(got.comment), _note(want.comment), reason: reason);
    expect(
      _note(got.startingComment),
      _note(want.startingComment),
      reason: reason,
    );
    expect(got.nags, want.nags, reason: reason);
  }
}

/// A note as the user reads it: the words and tokens, without the space
/// around them, and no note for an empty one.
///
/// Known byte change: annotating then removing a review rewrites each
/// reviewed note through `_joined` in chess/pgn/game_review.dart, so
/// `{ padded }` comes back as `{padded}` and an empty `{}` is dropped.
String? _note(String? comment) {
  final trimmed = comment?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

// ---------------------------------------------------------------------------
// Courses
// ---------------------------------------------------------------------------

final Generator<CourseFile> _courses = Generator(
  (r) => CourseFile([
    for (var i = r.between(2, 3); i > 0; i--)
      GeneratedFile(editableChapters(maxGames: 3).sample(r)),
  ]),
  shrinker: (c) => shrunkFile(c).whereType<CourseFile>(),
);

/// Every line of a course with moves carries, as its own id header, the id
/// it is trained under — unless its headers cannot take one, which nothing
/// the import writes is.
void _expectCoursePinned(CourseFile course) {
  // A course of one chapter is that chapter's own file, as it was.
  if (courseRead(course.parts).chapters.length < 2) return;
  final file = wholeFile(course.text);
  final ids = trainedIdsOf(file);
  for (final (index, line) in file.lines.indexed) {
    final id = ids[index];
    if (id == null || line.lineId == id) continue;
    expect(
      withIdHeader(line, id),
      isNull,
      reason:
          'game $index is trained under $id but says ${line.lineId}\n'
          '${line.text}',
    );
  }
}

// ---------------------------------------------------------------------------
// The generator's reach
// ---------------------------------------------------------------------------

final class _Tally {
  final landed = <EditKind, int>{};
  final refused = <String, int>{};
  int courses = 0;
  int notWhole = 0;
  int sharedIds = 0;

  void add(EditCase c) {
    if (c.file is CourseFile) courses++;
    final file = wholeFile(c.file.text);
    if (file.lines.any((line) => !line.isWhole)) notWhole++;
    final headers = [for (final line in file.lines) ?line.lineId];
    if (headers.toSet().length < headers.length) sharedIds++;
    for (final step in runEdits(c)) {
      switch (step.outcome) {
        case EditLanded():
          landed.update(step.spec.kind, (n) => n + 1, ifAbsent: () => 1);
        case EditRefused(:final reason):
          refused.update(reason, (n) => n + 1, ifAbsent: () => 1);
        case EditUnchanged():
          break;
      }
    }
  }

  @override
  String toString() =>
      'landed $landed\nrefused $refused\ncourses $courses, '
      'not whole $notWhole, shared ids $sharedIds';
}

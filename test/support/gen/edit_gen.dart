/// Edits for the edit laws: plain-data [EditSpec]s resolved against the file
/// they meet and made through the app's own chess edits.
///
/// An edit is ratios and a seed, never a path: a ratio picks a game, a move
/// or a chapter of whatever file it meets, so a file shrunk towards a minimal
/// failure still takes every edit of the case. Each edit lands the way the
/// workspace lands it ([landing], [fileLanding]): the ids it would change
/// pinned ([withIdsPinned]), a chapter of a course file put back into its
/// file, and the scope the store checks the new text against. A refusal is
/// an outcome, not a failure; the laws say which refusals they expect.
///
/// Files lean towards what the edits find hard: courses ([courseText] over
/// several imported chapters), `[LineID]`s shared by two games, and games
/// reading could not take whole.
library;

import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/pgn/chapter_edit.dart';
import 'package:chess_auto_prep/chess/pgn/chapter_edits.dart';
import 'package:chess_auto_prep/chess/pgn/chapter_sections.dart';
import 'package:chess_auto_prep/chess/pgn/comment_edits.dart';
import 'package:chess_auto_prep/chess/pgn/game_review.dart';
import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/chess/pgn/games_written.dart';
import 'package:chess_auto_prep/chess/pgn/line_edits.dart';
import 'package:chess_auto_prep/chess/pgn/line_moves.dart';
import 'package:chess_auto_prep/chess/pgn/repertoire_import.dart';
import 'package:chess_auto_prep/chess/pgn/study_edits.dart';
import 'package:chess_auto_prep/chess/pgn/tree_edit.dart';
import 'package:chess_auto_prep/storage/edit_scope.dart';
import 'package:chess_auto_prep/workspace/document_projection.dart';
import 'package:dartchess/dartchess.dart' show Side;

import '../props.dart';
import 'pgn_gen.dart';

// ---------------------------------------------------------------------------
// Files
// ---------------------------------------------------------------------------

/// Where the file an edit is made to comes from.
sealed class FileSource {
  const FileSource();

  String get text;
}

final class GeneratedFile extends FileSource {
  const GeneratedFile(this.spec);

  final ChapterSpec spec;

  @override
  String get text => renderChapter(spec).text;

  @override
  String toString() => 'GeneratedFile($spec)';
}

final class LiteralFile extends FileSource {
  const LiteralFile(this.text);

  @override
  final String text;

  @override
  String toString() => 'LiteralFile(${text.replaceAll('\n', r'\n')})';
}

/// A course: every part imported ([readImport]) and its chapters written as
/// one file ([courseText]) — what several exported chapters, concatenated
/// and imported, make.
final class CourseFile extends FileSource {
  const CourseFile(this.parts);

  final List<FileSource> parts;

  @override
  String get text => courseText(courseRead(parts), created: created);

  @override
  String toString() => 'CourseFile($parts)';
}

/// The stamp every generated heading carries.
final created = DateTime(2026, 9, 29, 12);

/// The chapters of every one of [parts], each under a title of its own.
ImportedChapters courseRead(List<FileSource> parts) {
  final chapters = <ImportedChapter>[];
  for (final part in parts) {
    final read = readImport(part.text, created: created);
    if (read is! ImportedChapters) continue;
    for (final chapter in read.chapters) {
      chapters.add(
        ImportedChapter(
          title: '${chapter.title.trim()} ${chapters.length + 1}'.trim(),
          text: chapter.text,
          lines: chapter.lines,
        ),
      );
    }
  }
  return ImportedChapters(
    chapters: chapters,
    lines: chapters.fold(0, (sum, chapter) => sum + chapter.lines),
    side: null,
  );
}

/// Ids two games of a file, or of two chapters of a course, both carry.
const sharedIds = ['line_ZTQgYzUgTmYzIGQ2IG', 'x', 'k-9f2'];

const _sectionNames = ['Najdorf', 'Dragon'];

/// Chapters from [chapterSpecs], leaning towards shared `[LineID]`s, named
/// chapters and games reading cannot take whole.
Generator<ChapterSpec> editableChapters({int maxGames = 4}) {
  final plain = chapterSpecs(maxGames: maxGames, maxPlies: 5);
  return Generator((r) => _leaning(r, plain.sample(r)), shrinker: plain.shrink);
}

ChapterSpec _leaning(Rand r, ChapterSpec spec) {
  final named = r.chance(40);
  return spec.copyWith(
    games: [for (final game in spec.games) _leaningGame(r, game, named)],
  );
}

ChapterGame _leaningGame(Rand r, ChapterGame game, bool named) {
  final extra = [
    if (r.chance(35)) HeaderSpec.tag('LineID', r.pick(sharedIds)),
    if (named && r.chance(80))
      HeaderSpec.tag('ChapterName', r.pick(_sectionNames)),
  ];
  final tagged = extra.isEmpty
      ? game
      : ChapterGame(
          headers: [game.headers.first, ...extra, ...game.headers.skip(1)],
          tree: game.tree,
          terminator: game.terminator,
          separator: game.separator,
          illegalAt: game.illegalAt,
          escapeLine: game.escapeLine,
          style: game.style,
        );
  return r.chance(20) ? tagged.copyWith(escapeLine: true) : tagged;
}

/// A file of one game or of several, or a course of two or three parts.
FileSource sampleFile(Rand r) => r.chance(30)
    ? CourseFile([
        for (var i = r.between(2, 3); i > 0; i--)
          GeneratedFile(editableChapters(maxGames: 2).sample(r)),
      ])
    : GeneratedFile(editableChapters().sample(r));

Iterable<FileSource> shrunkFile(FileSource file) sync* {
  switch (file) {
    case GeneratedFile(:final spec):
      yield* chapterSpecs().shrink(spec).map(GeneratedFile.new);
    case CourseFile(:final parts):
      for (var i = 0; i < parts.length; i++) {
        if (parts.length > 1) yield CourseFile([...parts]..removeAt(i));
        for (final smaller in shrunkFile(parts[i])) {
          yield CourseFile([...parts]..[i] = smaller);
        }
      }
    case LiteralFile():
      break;
  }
}

// ---------------------------------------------------------------------------
// Edits
// ---------------------------------------------------------------------------

enum EditKind {
  comment,
  glyph,
  addMove,
  renameLine,
  deleteLine,
  takeOut,
  moveChapter,
  fold,
  linesNamed,
  sectionRenamed,
  sectionRemoved,
  sideSet,
  annotate,
  removeReview,
  commentInReview,
  moveInReview,
}

/// The kinds that may take a game out of the file.
const removingKinds = {
  EditKind.deleteLine,
  EditKind.takeOut,
  EditKind.sectionRemoved,
  EditKind.fold,
};

/// One edit, as ratios in `[0, 1)` and a seed: [a] and [b] pick games or
/// moves of whatever file the edit meets, [n] picks the rest — the words, the
/// move played, the name given. [values] is a review's evaluations when the
/// case names them; otherwise they are drawn from [n].
final class EditSpec {
  const EditSpec(this.kind, {this.a = 0, this.b = 0, this.n = 0, this.values});

  final EditKind kind;
  final double a;
  final double b;
  final int n;
  final List<ReviewValue>? values;

  @override
  String toString() =>
      'EditSpec(${kind.name}, a: ${a.toStringAsFixed(3)}, '
      'b: ${b.toStringAsFixed(3)}, n: $n${values == null ? '' : ', values'})';
}

/// What the edits are made to: the whole file, one chapter of it by name,
/// or one game of it, as a study chapter is.
enum Focus { file, section, game }

/// A file and the edits made to it, one after another, each to what the
/// last one left.
final class EditCase {
  const EditCase(
    this.file, {
    this.focus = Focus.file,
    this.pick = 0,
    this.edits = const [],
  });

  final FileSource file;
  final Focus focus;

  /// Which chapter or game [focus] names.
  final int pick;
  final List<EditSpec> edits;

  EditCase copyWith({FileSource? file, Focus? focus, List<EditSpec>? edits}) =>
      EditCase(
        file ?? this.file,
        focus: focus ?? this.focus,
        pick: pick,
        edits: edits ?? this.edits,
      );

  @override
  String toString() => 'EditCase($focus#$pick $edits $file)';
}

/// Every kind, the fold and the review more often: a fold needs two games
/// from one position and a review one game, which a file of several games
/// seldom gives them.
const _leaningKinds = [
  ...EditKind.values,
  EditKind.fold,
  EditKind.fold,
  EditKind.fold,
  EditKind.annotate,
  EditKind.removeReview,
];

EditSpec sampleEdit(Rand r, {List<EditKind> kinds = _leaningKinds}) => EditSpec(
  r.pick(kinds),
  a: r.nextDouble(),
  b: r.nextDouble(),
  n: r.nextInt(1 << 20),
);

/// Up to three edits of any kind to a file from [sampleFile].
final Generator<EditCase> editCases = Generator(
  (r) => EditCase(
    sampleFile(r),
    focus: r.chance(20)
        ? Focus.game
        : r.chance(40)
        ? Focus.section
        : Focus.file,
    pick: r.nextInt(1 << 20),
    edits: [for (var i = r.between(1, 3); i > 0; i--) sampleEdit(r)],
  ),
  shrinker: shrunkCase,
);

Iterable<EditCase> shrunkCase(EditCase c) sync* {
  final edits = c.edits;
  for (var i = 0; i < edits.length && edits.length > 1; i++) {
    yield c.copyWith(edits: [...edits]..removeAt(i));
  }
  if (c.focus != Focus.file) yield c.copyWith(focus: Focus.file);
  for (final file in shrunkFile(c.file)) {
    yield c.copyWith(file: file);
  }
}

// ---------------------------------------------------------------------------
// The confirmed shapes
// ---------------------------------------------------------------------------

/// Game B stops at an illegal move, so reading does not take it whole.
const partlyRead = LiteralFile(
  '[Event "A"]\n\n1. d4 d5 2. c4 *\n\n'
  '[Event "B"]\n\n1. d4 d5 2. Ke3 Nf6 3. Nf3 {my note} *\n',
);

/// Three games play 1...d5, two of them with notes of their own on it.
const sharedNotes = LiteralFile(
  '[Event "A"]\n\n1. e4 d5 {first} *\n\n'
  '[Event "B"]\n\n1. e4 d5 {second} *\n\n'
  '[Event "C"]\n\n1. e4 d5 *\n',
);

/// 2...Nf6? reviewed with 2...Nc6 3.Bb5 a6 as the better line, the user
/// playing on in it and writing a note in it, then the review taken out.
const reviewOverUserMoves = EditCase(
  LiteralFile('[Event "R"]\n\n1. e4 e5 2. Nf3 Nf6 *\n'),
  focus: Focus.game,
  edits: [
    EditSpec(
      EditKind.annotate,
      values: [
        ReviewValue(20, '0.20', ['e2e4']),
        ReviewValue(30, '0.30', ['e7e5']),
        ReviewValue(30, '0.30', ['g1f3']),
        ReviewValue(30, '0.30', ['b8c6', 'f1b5', 'a7a6']),
        ReviewValue(300, '3.00', ['f3e5']),
      ],
    ),
    EditSpec(EditKind.moveInReview, a: .99),
    EditSpec(EditKind.commentInReview, a: .5),
    EditSpec(EditKind.removeReview),
  ],
);

/// Two exported chapters whose first lines carry the one short id their
/// shared 1.e4 c5 2.Nf3 d6 gives them, imported as one course.
const sharedSourceIds = CourseFile([
  LiteralFile(
    '[Event "Sicilian"]\n[LineID "line_ZTQgYzUgTmYzIGQ2IG"]\n\n'
    '1. e4 c5 2. Nf3 d6 *\n',
  ),
  LiteralFile(
    '[Event "Sicilian"]\n[LineID "line_ZTQgYzUgTmYzIGQ2IG"]\n\n'
    '1. e4 c5 2. Nf3 d6 3. d4 *\n',
  ),
]);

/// The shapes of the bugs the audits confirmed, which every law runs first
/// on every run.
const confirmedCases = [
  // Folding a partly-read line into another deleted what reading dropped.
  EditCase(partlyRead, edits: [EditSpec(EditKind.fold, b: .9)]),
  // A note edit overwrote a note on the same move the user never saw, or
  // cleared it.
  EditCase(sharedNotes, edits: [EditSpec(EditKind.comment, a: .9)]),
  EditCase(sharedNotes, edits: [EditSpec(EditKind.comment, a: .9, n: 1)]),
  // Removing a review deleted the user's moves and notes in its line.
  reviewOverUserMoves,
  // courseText left a shadowed source [LineID] unpinned; then a line taken
  // out above it and one added.
  EditCase(
    sharedSourceIds,
    focus: Focus.section,
    edits: [EditSpec(EditKind.deleteLine), EditSpec(EditKind.addMove, a: .9)],
  ),
];

// ---------------------------------------------------------------------------
// Making an edit
// ---------------------------------------------------------------------------

/// What one edit came to.
sealed class EditOutcome {
  const EditOutcome();
}

/// The edit is in the file: its text, the scope the store checks it
/// against, and where each game of it came from ([games]).
final class EditLanded extends EditOutcome {
  const EditLanded(this.landed, this.games);

  final Landing landed;
  final GamesArranged games;
}

final class EditUnchanged extends EditOutcome {
  const EditUnchanged();
}

/// The edit said why it could not be made, which is one of its answers.
final class EditRefused extends EditOutcome {
  const EditRefused(this.reason);

  final String reason;
}

/// What an edit was made to: the whole file, where its chapter sits in it,
/// and the chapter the edit saw.
typedef Shown = ({Chapter file, SectionView? view, Chapter chapter});

/// One edit made: to what, and what it came to.
final class EditStep {
  const EditStep({
    required this.spec,
    required this.before,
    required this.shown,
    required this.outcome,
    this.sans,
    this.fold,
  });

  final EditSpec spec;

  /// The file's text before the edit.
  final String before;
  final Shown shown;
  final EditOutcome outcome;

  /// The move a comment or glyph went on, as the moves that reach it.
  final List<String>? sans;

  /// For a fold, the game folded in and the one it went into, as indexes
  /// among the file's games.
  final ({int host, int arriving})? fold;

  /// The file's text after the edit, or null when it did not land.
  String? get after => switch (outcome) {
    EditLanded(:final landed) => landed.text,
    _ => null,
  };

  /// Whether the edit was to a repertoire, whose lines are trained by id,
  /// rather than to one game of a study.
  bool get trained => shown.chapter.game == null;

  @override
  String toString() => '$spec -> ${outcome.runtimeType}';
}

/// [file] parsed as the whole file, whatever the case focuses on.
Chapter wholeFile(String text) => parseChapter(name: 'Laws', text: text);

/// The chapter of [text] a case focusing on [focus] and [pick] edits.
Shown shownOf(String text, Focus focus, int pick) {
  final file = wholeFile(text);
  switch (focus) {
    case Focus.file:
      return (file: file, view: null, chapter: file);
    case Focus.game:
      final game = file.lines.isEmpty ? null : pick % file.lines.length;
      final chapter = parseChapter(name: 'Laws', text: text, game: game);
      return (file: file, view: null, chapter: chapter);
    case Focus.section:
      final sections = chapterSections(file.lines);
      final view = partOf(file, sections[pick % sections.length]);
      return (file: file, view: view, chapter: view?.chapter ?? file);
  }
}

/// Every edit of [c], one after another, each made to what the last one
/// left on disk.
List<EditStep> runEdits(EditCase c) {
  var text = c.file.text;
  final steps = <EditStep>[];
  for (final spec in c.edits) {
    final step = makeEdit(shownOf(text, c.focus, c.pick), text, spec);
    steps.add(step);
    text = step.after ?? text;
  }
  return steps;
}

/// [spec] made to [shown], whose file is [text], and landed as the
/// workspace lands it.
EditStep makeEdit(Shown shown, String text, EditSpec spec) {
  final chapter = shown.chapter;
  final made = switch (spec.kind) {
    EditKind.comment ||
    EditKind.glyph ||
    EditKind.commentInReview => _annotation(chapter, spec),
    EditKind.addMove || EditKind.moveInReview => _moved(chapter, spec),
    EditKind.fold => _folded(chapter, spec),
    EditKind.linesNamed ||
    EditKind.sectionRenamed ||
    EditKind.sectionRemoved => _fileEdit(shown, spec),
    _ => (edit: _lineEdit(chapter, spec), written: null, sans: null),
  };
  return EditStep(
    spec: spec,
    before: text,
    shown: shown,
    outcome: _landed(shown, spec, made.edit, made.written),
    sans: made.sans,
    fold: spec.kind == EditKind.fold ? _foldPlaces(shown, spec) : null,
  );
}

/// What an edit made, before it lands: the edit, the games it says it
/// wrote when it says it that way, and the move it was on.
typedef _Made = ({ChapterEdit edit, GamesWritten? written, List<String>? sans});

EditOutcome _landed(
  Shown shown,
  EditSpec spec,
  ChapterEdit edit,
  GamesWritten? written,
) {
  switch (edit) {
    case ChapterUnchanged():
      return const EditUnchanged();
    case ChapterEditRefused(:final reason):
      return EditRefused(reason);
    case ChapterEdited(chapter: final edited, :final games):
      final view = shown.view;
      final Landing? landed = _isFileEdit(spec.kind) && view != null
          ? fileLanding(view.file, edited, games, view.section)
          : landing(shown.chapter, view, edited, games, written: written);
      if (landed == null) {
        return const EditRefused('a game could not be given its chapter');
      }
      return EditLanded(landed, arrangementOf(landed, shown.file));
  }
}

bool _isFileEdit(EditKind kind) =>
    kind == EditKind.linesNamed ||
    kind == EditKind.sectionRenamed ||
    kind == EditKind.sectionRemoved;

/// What [landed] says it did to the games of [file].
GamesArranged arrangementOf(Landing landed, Chapter file) =>
    switch (landed.scope) {
      GamesRearranged(:final arranged) => arranged,
      GamesEdited(:final written) => GamesArranged.of(
        written,
        before: file.lines.length,
      ),
      WholeDocument() || RestoredVersion() => throw StateError(
        'an edit landed as ${landed.scope.runtimeType}',
      ),
    };

int _index(double ratio, int length) =>
    length == 0 ? 0 : (ratio * length).floor().clamp(0, length - 1);

const _notes = ['Ours', '', 'plan: Rad1', 'two\nlines'];

/// The words a comment edit of [spec] writes.
String noteOf(EditSpec spec) => _notes[spec.n % _notes.length];
const _names = ['Main line', 'the "real" one', 'Line 1'];
const _sections = [null, 'Najdorf', 'Dragon', 'New'];

_Made _annotation(Chapter chapter, EditSpec spec) {
  final tree = chapter.tree;
  final paths = switch (spec.kind) {
    EditKind.commentInReview => reviewLinePaths(tree),
    EditKind.glyph => nodePaths(tree),
    _ => [const NodePath.root(), ...nodePaths(tree)],
  };
  if (paths.isEmpty) {
    return (edit: const ChapterUnchanged(), written: null, sans: null);
  }
  final at = paths[_index(spec.a, paths.length)];
  final result = spec.kind == EditKind.glyph
      ? setGlyph(
          chapter,
          at: at,
          nag: const [null, 1, 2, 3, 4, 5, 6][spec.n % 7],
        )
      : setComment(chapter, at: at, text: noteOf(spec));
  final sans = [for (final node in tree.lineTo(at)) node.san];
  return switch (result) {
    CommentWritten(chapter: final edited) when identical(edited, chapter) => (
      edit: const ChapterUnchanged(),
      written: null,
      sans: sans,
    ),
    CommentWritten(chapter: final edited, :final written) => (
      edit: ChapterEdited(
        edited,
        GamesArranged.of(written, before: chapter.lines.length),
      ),
      written: written,
      sans: sans,
    ),
    GameNotWhole() => (
      edit: const ChapterEditRefused(lineNotWholeReason),
      written: null,
      sans: sans,
    ),
    CommentUnwritable(:final reason) => (
      edit: ChapterEditRefused(reason),
      written: null,
      sans: sans,
    ),
  };
}

_Made _moved(Chapter chapter, EditSpec spec) {
  final tree = chapter.tree;
  final paths = spec.kind == EditKind.moveInReview
      ? reviewLinePaths(tree)
      : [const NodePath.root(), ...nodePaths(tree)];
  const none = (edit: ChapterUnchanged(), written: null, sans: null);
  if (paths.isEmpty) return none;
  final at = paths[_index(spec.a, paths.length)];
  final position = positionOf(tree.fenAt(at));
  final moves = [
    if (position != null)
      for (final move in legalMovesOf(position)) move.uci,
  ];
  if (moves.isEmpty) return none;
  final uci = moves[spec.n % moves.length];
  switch (addMove(chapter, at: at, uci: uci)) {
    case MoveAdded(:final written) when _nothing(written):
      return none;
    case MoveAdded(chapter: final edited, :final written, :final path):
      final arranged = GamesArranged.of(written, before: chapter.lines.length);
      final sans = [for (final node in edited.tree.lineTo(path)) node.san];
      return (
        edit: ChapterEdited(edited, arranged),
        written: written,
        sans: sans,
      );
    case MoveIllegal():
      throw StateError('a legal move $uci was called illegal');
    case MoveNotWritten():
      throw StateError('addMove could not write $uci, which it never may');
    case MoveRefused(:final reason):
      return (edit: ChapterEditRefused(reason), written: null, sans: null);
  }
}

bool _nothing(GamesWritten written) =>
    written.rewritten.isEmpty && written.appended == 0;

ChapterEdit _lineEdit(Chapter chapter, EditSpec spec) {
  final count = chapter.lines.length;
  final a = _index(spec.a, count);
  return switch (spec.kind) {
    EditKind.renameLine => renamedLine(
      chapter,
      game: a,
      name: _names[spec.n % _names.length],
    ),
    EditKind.deleteLine => lineDeleted(chapter, game: a),
    EditKind.takeOut => linesTakenOut(
      chapter,
      games: {a, _index(spec.b, count)},
    ),
    // Only a study's games are moved one place at a time; a repertoire's
    // lines move between chapters, which is a transfer of two files.
    EditKind.moveChapter when chapter.game != null => moveChapter(
      chapter,
      index: a,
      by: spec.n.isEven ? 1 : -1,
    ),
    EditKind.sideSet when chapter.game == null => sideSet(
      chapter,
      spec.n.isEven ? Side.white : Side.black,
    ),
    EditKind.annotate => annotateGame(
      chapter,
      spec.values ?? reviewValues(chapter.tree, spec.n),
    ),
    EditKind.removeReview => removeReview(chapter),
    _ => const ChapterUnchanged(),
  };
}

/// Where the fold of [spec] takes its games from, among the file's games.
({int host, int arriving})? _foldPlaces(Shown shown, EditSpec spec) {
  final (:host, :arriving) = _foldGames(shown.chapter, spec);
  if (host == arriving) return null;
  final places = shown.view?.places;
  return places == null
      ? (host: host, arriving: arriving)
      : (host: places[host], arriving: places[arriving]);
}

({int host, int arriving}) _foldGames(Chapter chapter, EditSpec spec) {
  final count = chapter.lines.length;
  return (host: _index(spec.a, count), arriving: _index(spec.b, count));
}

/// One line dropped on another: grafted into it, then taken out, as the
/// library does it — two edits, whose saves collapse into one.
_Made _folded(Chapter chapter, EditSpec spec) {
  final (:host, :arriving) = _foldGames(chapter, spec);
  const none = (edit: ChapterUnchanged(), written: null, sans: null);
  if (host == arriving) return none;
  final line = chapter.lines[arriving];
  final grafted = lineGraftedInto(chapter, host: host, line: line);
  final (into, first) = switch (grafted) {
    ChapterEdited(chapter: final edited, :final games) => (edited, games),
    ChapterUnchanged() => (chapter, null),
    ChapterEditRefused() => (null, null),
  };
  if (into == null) return (edit: grafted, written: null, sans: null);
  final taken = linesTakenOut(into, games: {arriving});
  if (taken is! ChapterEdited) return (edit: taken, written: null, sans: null);
  final both = first == null
      ? taken.games
      : composedArrangement(first, taken.games);
  if (both == null) throw StateError('a fold did not compose');
  return (edit: ChapterEdited(taken.chapter, both), written: null, sans: null);
}

/// An edit to the whole file the chapter is in, as the library makes one.
_Made _fileEdit(Shown shown, EditSpec spec) {
  final file = shown.view == null ? shown.chapter : shown.file;
  final sections = chapterSections(file.lines);
  final count = file.lines.length;
  final from = sections[_index(spec.a, sections.length)];
  final name = _sections[spec.n % _sections.length];
  final edit = switch (spec.kind) {
    EditKind.linesNamed => linesNamed(file, {
      _index(spec.a, count),
      _index(spec.b, count),
    }, name),
    EditKind.sectionRenamed => sectionRenamed(file, from, name ?? 'Renamed'),
    _ => sectionRemoved(file, from),
  };
  return (edit: edit, written: null, sans: null);
}

// ---------------------------------------------------------------------------
// Trees
// ---------------------------------------------------------------------------

/// Every move of [tree], parents before their children.
List<NodePath> nodePaths(GameTree tree) =>
    _pathsBelow(tree.children, const NodePath.root());

List<NodePath> _pathsBelow(List<MoveNode> nodes, NodePath at) => [
  for (final (index, node) in nodes.indexed) ...[
    at.child(index),
    ..._pathsBelow(node.children, at.child(index)),
  ],
];

final _reviewLine = RegExp(r'\[%cap_review_line');

/// Every move of a line a review added: its first move, which carries the
/// review's mark, and everything after it.
List<NodePath> reviewLinePaths(GameTree tree) =>
    _reviewBelow(tree.children, const NodePath.root(), inside: false);

List<NodePath> _reviewBelow(
  List<MoveNode> nodes,
  NodePath at, {
  required bool inside,
}) => [
  for (final (index, node) in nodes.indexed) ...[
    if (inside || _reviewLine.hasMatch(node.comment ?? '')) at.child(index),
    ..._reviewBelow(
      node.children,
      at.child(index),
      inside: inside || _reviewLine.hasMatch(node.comment ?? ''),
    ),
  ],
];

/// Evaluations for the main line of [tree], drawn from [seed]: a score and
/// a line of up to four legal moves at each position, for the first few
/// positions or all of them.
List<ReviewValue> reviewValues(GameTree tree, int seed) {
  final r = Rand(seed);
  final fens = [tree.rootFen, for (final node in tree.mainLine) node.fen];
  return [
    for (final fen in fens.take(r.between(1, fens.length))) _value(r, fen),
  ];
}

ReviewValue _value(Rand r, Fen fen) {
  final cp = r.between(-400, 400);
  final pv = <String>[];
  var position = positionOf(fen);
  for (var i = r.between(0, 4); i > 0 && position != null; i--) {
    final moves = legalMovesOf(position);
    if (moves.isEmpty) break;
    final move = r.pick(moves);
    pv.add(move.uci);
    position = position.play(move);
  }
  return ReviewValue(cp, (cp / 100).toStringAsFixed(2), pv);
}

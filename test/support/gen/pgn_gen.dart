/// Chapter files generated together with what they mean.
///
/// A [ChapterSpec] is plain data: games of real moves ([growTree]), their
/// header lines, and how the file is laid out. [renderChapter] writes it the
/// many ways files in the wild do — a byte-order mark, `//`, banner, `%` and
/// `;` preambles, unknown, duplicate and escaped tags, `[LineID]` and
/// `[ChapterName]`, machine tokens, NAGs 1–255, glyphs, `;` and `%`
/// furniture among the moves, CRLF, wrapped lines, every terminator — and
/// says for each game what a reader must make of it ([GameTruth]). The
/// renderer is written apart from the app's writer, so a law that compares
/// the two is not the app agreeing with itself.
library;

import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/chess/pgn/tree_edit.dart';

import '../props.dart';
import 'tree_gen.dart';

/// One line of a game's header block as the file writes it.
final class HeaderSpec {
  /// A `[key "value"]` tag. [raw] is how the file spells it; by default the
  /// standard form, with `\` and `"` escaped.
  HeaderSpec.tag(this.key, String this.value, {String? raw, this.trailer})
    : raw = raw ?? '[$key "${_escaped(value)}"]';

  /// A header line that is not a tag: a `%` line, a mistyped bracket.
  const HeaderSpec.line(this.raw) : key = null, value = null, trailer = null;

  final String? key;

  /// The value as prose, what a reader must unescape [raw] to.
  final String? value;
  final String raw;

  /// What follows the line when it is not a newline: a space before
  /// another tag on the same line, or spaces before the newline. Null is a
  /// plain newline.
  final String? trailer;

  bool get isTag => key != null;

  @override
  String toString() => '$raw${trailer ?? r'\n'}';
}

String _escaped(String value) =>
    value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');

/// A game of a generated chapter.
final class ChapterGame {
  const ChapterGame({
    required this.headers,
    required this.tree,
    required this.terminator,
    this.separator = '\n',
    this.illegalAt,
    this.escapeLine = false,
    this.style = 0,
  });

  /// The header block, `[Event]` first: that is what starts a game.
  final List<HeaderSpec> headers;

  /// The moves the game holds, before [illegalAt] cuts any.
  final GameTree tree;

  /// The game-termination marker, or null for none.
  final String? terminator;

  /// The whitespace between the header block and the moves, with `\n` for
  /// the chapter's newline.
  final String separator;

  /// A move written as one that is not legal where it stands. Reading
  /// stops that branch there, so the truth is [tree] without it and without
  /// whatever the file wrote after it in the same line.
  final NodePath? illegalAt;

  /// A `%` escape line among the moves, which the reader must name.
  final bool escapeLine;

  /// Seeds the choices [renderChapter] makes for each token: how a move is
  /// numbered, a glyph for `$1`, a comment written with `;` or in two parts.
  final int style;

  ChapterGame copyWith({
    GameTree? tree,
    String? terminator,
    bool? escapeLine,
    bool dropIllegal = false,
  }) => ChapterGame(
    headers: headers,
    tree: tree ?? this.tree,
    terminator: terminator ?? this.terminator,
    separator: separator,
    illegalAt: dropIllegal ? null : illegalAt,
    escapeLine: escapeLine ?? this.escapeLine,
    style: style,
  );

  @override
  String toString() =>
      'ChapterGame(${headers.join()} sep=${separator.length} '
      'moves=${_count(tree.children)} end=$terminator'
      '${illegalAt == null ? '' : ' illegal@$illegalAt'}'
      '${escapeLine ? ' %line' : ''} style=$style)';
}

int _count(List<MoveNode> nodes) =>
    nodes.fold(nodes.length, (sum, node) => sum + _count(node.children));

/// How a chapter ends its lines.
enum Newlines { lf, crlf, crlfHeaders }

/// A generated chapter file.
final class ChapterSpec {
  const ChapterSpec({
    required this.games,
    this.bom = false,
    this.preamble = const [],
    this.trailers = const [],
    this.newlines = Newlines.lf,
    this.width = 1000,
  });

  final List<ChapterGame> games;
  final bool bom;

  /// Lines above the first game, each written with the chapter's newline.
  final List<String> preamble;

  /// The whitespace after each game, `\n` standing for the chapter's
  /// newline; a game past the end of the list gets a blank line, and the
  /// last game gets the last entry (an empty one leaves no final newline).
  final List<String> trailers;
  final Newlines newlines;

  /// Movetext lines wrap past this many characters.
  final int width;

  ChapterSpec copyWith({
    List<ChapterGame>? games,
    bool? bom,
    List<String>? preamble,
    Newlines? newlines,
    int? width,
  }) => ChapterSpec(
    games: games ?? this.games,
    bom: bom ?? this.bom,
    preamble: preamble ?? this.preamble,
    trailers: trailers,
    newlines: newlines ?? this.newlines,
    width: width ?? this.width,
  );

  @override
  String toString() =>
      'ChapterSpec(bom=$bom preamble=$preamble trailers=$trailers '
      '$newlines width=$width games=$games)';
}

/// What reading one game must give.
final class GameTruth {
  const GameTruth({
    required this.whole,
    required this.tree,
    required this.headers,
    required this.terminator,
    required this.separator,
    required this.section,
    required this.lineId,
    required this.illegal,
    required this.oldAppCuts,
  });

  /// Read with no issue at all.
  final bool whole;

  /// The tree the reader builds, [ChapterGame.illegalAt] cut away.
  final GameTree tree;

  /// Every header line as the reader keeps it: its text and what followed.
  final List<({String text, String trailer})> headers;
  final String? terminator;
  final String separator;

  /// The `[ChapterName]` the game names, trimmed; null for none.
  final String? section;

  /// The id the game is trained under by its own tags; null for none.
  final String? lineId;

  /// Whether one branch stops at a move that is not legal.
  final bool illegal;

  /// How many lines of its comments start with `[Event `: the old app starts
  /// a game at each of them, which is the one place the two apps are known
  /// to cut a file differently.
  final int oldAppCuts;
}

/// A chapter's text and what each of its games means.
typedef RenderedChapter = ({
  String text,
  String preamble,
  List<GameTruth> games,
});

/// [spec] as a file, with the truth of every game.
RenderedChapter renderChapter(ChapterSpec spec) {
  final body = spec.newlines == Newlines.lf ? '\n' : '\r\n';
  final head = spec.newlines == Newlines.crlf ? '\r\n' : body;
  final chapter = StringBuffer(spec.bom ? '﻿' : '');
  for (final line in spec.preamble) {
    chapter.write('${line.replaceAll('\n', body)}$body');
  }
  if (spec.preamble.isNotEmpty) chapter.write(body);
  final preamble = chapter.toString();
  final truths = <GameTruth>[];
  for (final (index, game) in spec.games.indexed) {
    final rendered = _Game(game, body: body, head: head, width: spec.width);
    chapter.write(rendered.render());
    truths.add(rendered.truth());
    final last = index == spec.games.length - 1;
    final trailer = last
        ? spec.trailers.lastOrNull ?? '\n'
        : index < spec.trailers.length
        ? spec.trailers[index]
        : '\n\n';
    chapter.write(trailer.replaceAll('\n', body));
  }
  return (text: chapter.toString(), preamble: preamble, games: truths);
}

/// One game being written.
final class _Game {
  _Game(this.spec, {required this.body, required this.head, required int width})
    : rand = Rand(spec.style),
      out = _Out(body, width);

  final ChapterGame spec;
  final String body;
  final String head;
  final Rand rand;
  final _Out out;
  final StringBuffer _header = StringBuffer();
  bool _escaped = false;
  int _oldAppCuts = 0;

  String render() {
    for (final line in spec.headers) {
      _header.write('${line.raw}${_trailerOf(line)}');
    }
    _header.write(spec.separator.replaceAll('\n', body));
    _movetext();
    return '$_header${out.text}';
  }

  String _trailerOf(HeaderSpec line) =>
      (line.trailer ?? '\n').replaceAll('\n', head);

  void _movetext() {
    final root = spec.tree.rootComment;
    if (root != null) _comment(root);
    _line(spec.tree.children, spec.tree.rootFen, const NodePath.root());
    final end = _terminator;
    if (end != null) out.word(end);
  }

  /// Written when the game has one, and always for a game with nothing
  /// else among its moves: a game is never only its header.
  String? get _terminator =>
      spec.terminator ??
      (spec.tree.isEmpty && spec.tree.rootComment == null ? '*' : null);

  void _line(List<MoveNode> children, Fen from, NodePath path) {
    var siblings = children;
    var before = from;
    var at = path;
    var first = true;
    while (siblings.isNotEmpty) {
      final main = siblings.first;
      _move(main, before, at.mainChild, numbered: first);
      for (final (index, variation) in siblings.indexed.skip(1)) {
        out.word('(');
        _move(variation, before, at.child(index), numbered: true);
        _line(variation.children, variation.fen, at.child(index));
        out.word(')');
      }
      if (at.isRoot && spec.escapeLine) _escape();
      siblings = main.children;
      before = main.fen;
      at = at.mainChild;
      first = false;
    }
  }

  void _escape() {
    _escaped = true;
    out.newLine();
    out.raw('% an escaped line 9. Qxf7#');
    out.newLine();
  }

  void _move(
    MoveNode node,
    Fen before,
    NodePath path, {
    required bool numbered,
  }) {
    final starting = node.startingComment;
    if (starting != null) _comment(starting);
    final written = path == spec.illegalAt
        ? illegalSanFrom(before, rand)
        : node.spelling ?? node.san;
    final number = _number(before, numbered || before.whiteToMove);
    final glyph = _glyph(node.nags);
    if (number != null && rand.chance(30)) {
      out.word('$number$written$glyph');
    } else {
      if (number != null) out.word(number);
      out.word('$written$glyph');
    }
    if (isEnPassant(before, node) && rand.chance(50)) out.word('e.p.');
    for (final nag in node.nags.skip(glyph.isEmpty ? 0 : 1)) {
      out.word('\$$nag');
    }
    final comment = node.comment;
    if (comment != null) _comment(comment);
  }

  /// `12.` or `12...`, a course's `12.` for Black, or nothing: the reader
  /// takes whose move it is from the board, never from the number.
  String? _number(Fen before, bool wanted) {
    final n = before.fullMove;
    if (before.whiteToMove) return wanted || rand.chance(80) ? '$n.' : null;
    if (!wanted) return rand.chance(10) ? '$n...' : null;
    return rand.chance(15) ? '$n.' : '$n...';
  }

  String _glyph(List<int> nags) {
    final first = nags.firstOrNull;
    if (first == null || first > 6 || !rand.chance(50)) return '';
    return const ['!', '?', '!!', '??', '!?', '?!'][first - 1];
  }

  /// [text] as a `{}` comment, a `;` comment or two `{}` comments in a row,
  /// which a reader joins with a space.
  void _comment(String text) {
    final flat = !text.contains('\n') && !text.contains('\r');
    final tail = text.isEmpty ? 0 : text.codeUnitAt(text.length - 1);
    if (flat && !_isTrimmed(tail) && rand.chance(20)) {
      out.word(';$text');
      out.newLine();
      return;
    }
    final space = text.indexOf(' ');
    final written = text.replaceAll('\n', body);
    final parts = space >= 0 && rand.chance(20)
        ? [written.substring(0, space), written.substring(space + 1)]
        : [written];
    for (final part in parts) {
      out.word('{$part}');
      _oldAppCuts += _eventLines(part);
    }
  }

  GameTruth truth() {
    final cut = spec.illegalAt;
    final tree = _withNewlines(spec.tree, body);
    return GameTruth(
      whole: cut == null && !_escaped,
      tree: cut == null ? tree : _cut(tree, cut),
      headers: [
        for (final line in spec.headers)
          (text: line.raw, trailer: _trailerOf(line)),
      ],
      terminator: _terminator,
      separator: spec.separator.replaceAll('\n', body),
      section: _nonEmpty(_value('ChapterName')),
      // The last tag under a key, as the old app reads headers into a map.
      lineId: [
        for (final key in const ['LineID', 'LineId', 'Id', 'Line', 'Guid'])
          _nonEmpty(
            spec.headers.where((line) => line.key == key).lastOrNull?.value,
          ),
      ].nonNulls.firstOrNull,
      illegal: cut != null,
      oldAppCuts: _oldAppCuts,
    );
  }

  String? _value(String key) =>
      spec.headers.where((line) => line.key == key).firstOrNull?.value;
}

String? _nonEmpty(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

/// How many lines of a comment's [text] after its first begin, past spaces,
/// tabs, carriage returns and byte-order marks, with `[Event `: the lines the
/// old app's splitter starts a game at, comment or not.
int _eventLines(String text) => text
    .split('\n')
    .skip(1)
    .where((line) => line.replaceFirst(_oldAppBlanks, '').startsWith('[Event '))
    .length;

final _oldAppBlanks = RegExp('^[ \t\r\uFEFF]*');

/// Whether a line ending with [unit] loses it when the game's text is
/// trimmed: a `;` comment last in a game runs to the end of it.
bool _isTrimmed(int unit) =>
    unit == 0x20 || unit == 0x09 || unit == 0xFEFF || unit == 0xA0;

/// Movetext as it is written, wrapping lines at a width.
final class _Out {
  _Out(this.newline, this.width);

  final String newline;
  final int width;
  final StringBuffer _buffer = StringBuffer();
  int _column = 0;
  bool _fresh = true;

  String get text => _buffer.toString();

  void word(String word) {
    if (!_fresh) {
      if (_column + word.length >= width) {
        _buffer.write(newline);
        _column = 0;
      } else {
        _buffer.write(' ');
        _column++;
      }
    }
    _buffer.write(word);
    _column += word.length;
    _fresh = false;
  }

  void raw(String line) {
    _buffer.write(line);
    _column += line.length;
    _fresh = false;
  }

  /// Ends the line; a line already ended is not ended twice.
  void newLine() {
    if (_fresh && _buffer.isNotEmpty) return;
    _buffer.write(newline);
    _column = 0;
    _fresh = true;
  }
}

/// A SAN no piece of the side to move can play from [before], though it
/// reads as a move.
String illegalSanFrom(Fen before, Rand rand) {
  final position = positionOf(before)!;
  const candidates = [
    'Qd4', 'Nd5', 'Bb5', 'Ke2', 'Rh3', 'e5', 'd4', 'a6', 'h3', //
    'Nc6', 'Nf6', 'Kd7', 'Qh5', 'Ra8', 'b4', 'g5', 'Bc4', 'Kb1',
  ];
  final start = rand.nextInt(candidates.length);
  for (var i = 0; i < candidates.length; i++) {
    final san = candidates[(start + i) % candidates.length];
    if (!_plays(position.parseSan, san)) return san;
  }
  // A king to the square it stands on, which no position allows.
  return 'Ke1e1';
}

bool _plays(Object? Function(String) parse, String san) {
  try {
    return parse(san) != null;
  } on Object {
    return false;
  }
}

/// [tree] with every comment's newlines written as [newline], as the file
/// holds them.
GameTree _withNewlines(GameTree tree, String newline) {
  String? fix(String? text) => text?.replaceAll('\n', newline);
  List<MoveNode> walk(List<MoveNode> nodes) => [
    for (final node in nodes)
      MoveNode(
        san: node.san,
        uci: node.uci,
        fen: node.fen,
        spelling: node.spelling,
        startingComment: fix(node.startingComment),
        comment: fix(node.comment),
        nags: node.nags,
        children: walk(node.children),
      ),
  ];
  return GameTree(
    rootFen: tree.rootFen,
    rootComment: fix(tree.rootComment),
    children: walk(tree.children),
  );
}

/// [tree] as a reader leaves it when the move at [at] is not legal: the
/// move is gone, and so is everything written after it in its own line —
/// every other move of that line when it is the main move, or only itself
/// when it opens a variation of its own.
GameTree _cut(GameTree tree, NodePath at) {
  final parent = at.parent;
  final index = at.indexes.last;
  List<MoveNode> kept(List<MoveNode> siblings) => index == 0
      ? const []
      : [...siblings.take(index), ...siblings.skip(index + 1)];
  if (parent.isRoot) {
    return GameTree(
      rootFen: tree.rootFen,
      rootComment: tree.rootComment,
      children: kept(tree.children),
    );
  }
  return withNodeChanged(
    tree,
    parent,
    (node) => node.copyWith(children: kept(node.children)),
  );
}

// ---------------------------------------------------------------------------
// The generator
// ---------------------------------------------------------------------------

/// Chapters of up to [maxGames] games of up to [maxPlies] plies each.
///
/// Plies stay few on purpose: every node is a legality check, and a law
/// over two hundred chapters should take seconds.
Generator<ChapterSpec> chapterSpecs({int maxGames = 3, int maxPlies = 6}) =>
    Generator(
      (r) => ChapterSpec(
        games: [
          for (var i = r.between(1, maxGames); i > 0; i--)
            chapterGame(r, maxPlies: maxPlies),
        ],
        bom: r.chance(15),
        preamble: [
          for (var i = r.chance(50) ? r.between(1, 3) : 0; i > 0; i--)
            r.pick(_preambleLines),
        ],
        trailers: [
          for (var i = 0; i < maxGames; i++) r.pick(_betweenGames),
          r.pick(const ['\n', '', '\n\n']),
        ],
        newlines: r.chance(70) ? Newlines.lf : r.pick(Newlines.values),
        width: r.chance(50) ? 1000 : r.pick(const [30, 60, 79]),
      ),
      shrinker: _shrunkChapter,
    );

const _preambleLines = [
  '// Repertoire',
  '// Color: Black',
  '// Created on 2026-09-19 14:07:33',
  'My Repertoire',
  '{ A banner\nover two lines }',
  '% exported by a tool',
  '; a note on the file',
];

const _betweenGames = ['\n\n', '\n', '\n\n\n', ' \n\n', '\n \n'];

/// One game of a chapter: its headers, a tree from one of [treeRoots], and
/// now and then a move that is not legal or a `%` line among the moves.
ChapterGame chapterGame(Rand r, {int maxPlies = 6}) {
  final root = r.chance(60) ? treeRoots.first : r.pick(treeRoots);
  final tree = GameTree(
    rootFen: root,
    rootComment: r.chance(20) ? treeComment(r) : null,
    children: growTree(r, root, r.between(0, maxPlies), spellings: true),
  );
  final paths = _pathsOf(tree.children, const NodePath.root());
  final headers = _headers(r, root);
  final sameLine = headers.last.trailer == ' ';
  return ChapterGame(
    headers: headers,
    tree: tree,
    terminator: r.pick(const [null, '*', '*', '1-0', '0-1', '1/2-1/2']),
    separator: sameLine ? '' : r.pick(const ['\n', '\n', '', '\n\n', ' \n']),
    illegalAt: paths.isNotEmpty && r.chance(15) ? r.pick(paths) : null,
    escapeLine: r.chance(8),
    style: r.nextInt(1 << 30),
  );
}

List<NodePath> _pathsOf(List<MoveNode> nodes, NodePath at) => [
  for (final (index, node) in nodes.indexed) ...[
    at.child(index),
    ..._pathsOf(node.children, at.child(index)),
  ],
];

List<HeaderSpec> _headers(Rand r, Fen root) {
  final lines = <HeaderSpec>[
    r.chance(15)
        ? HeaderSpec.tag('Event', r'c:\games', raw: r'[Event "c:\games"]')
        : HeaderSpec.tag('Event', r.pick(_events)),
    for (var i = r.between(0, 5); i > 0; i--) _header(r),
    if (root != treeRoots.first && r.nextBool()) HeaderSpec.tag('SetUp', '1'),
    if (root != treeRoots.first) HeaderSpec.tag('FEN', root.value),
  ];
  // Any tag but `[Event`, which on a line of its own starts another game.
  final repeatable = lines.where((l) => l.isTag && l.key != 'Event').toList();
  if (repeatable.isNotEmpty && r.chance(15)) lines.add(r.pick(repeatable));
  return [
    for (final (index, line) in lines.indexed)
      _trailed(r, line, next: lines.elementAtOrNull(index + 1)),
  ];
}

const _events = [
  'Line 1',
  'the "real" one',
  r'back\slash',
  'a {b',
  ' ',
  '½ → ∞',
];

HeaderSpec _header(Rand r) => switch (r.nextInt(12)) {
  0 => HeaderSpec.tag('Site', 'https://lichess.org/study/abc'),
  1 => HeaderSpec.tag('Date', '2026.09.??'),
  2 => HeaderSpec.tag('White', 'A. Player'),
  3 => HeaderSpec.tag('Result', r.pick(const ['*', '1-0', '1/2-1/2'])),
  4 => HeaderSpec.tag(
    r.pick(const ['CumProb', 'SM2Interval', 'X-Custom+Tag', 'Opening_ECO']),
    r.pick(const ['12.5%', '3', 'v', 'B90']),
  ),
  5 => HeaderSpec.tag('Annotator', r'a "q" b\c'),
  6 => HeaderSpec.tag(
    r.pick(const ['LineID', 'LineID', 'LineId', 'Guid']),
    r.pick(const ['abc123', ' spaced ', '', 'k-9f2']),
  ),
  7 => HeaderSpec.tag(
    'ChapterName',
    r.pick(const ['Sicilian', 'Najdorf 6.Bg5', ' ', '']),
  ),
  8 => HeaderSpec.tag(
    'Round',
    '1',
    raw: r.pick(const ['[Round   "1"]', '[Round\t"1"]']),
  ),
  9 => const HeaderSpec.line('% exported by a tool'),
  10 => const HeaderSpec.line('[Broken]'),
  _ => HeaderSpec.tag('Black', 'B. Player'),
};

/// [line] followed by a space before [next] on the same line, spaces before
/// its newline, or its newline alone. Only a tag can share its line: a `%`
/// line must start one, and anything after a line that is not a tag belongs
/// to that line.
HeaderSpec _trailed(Rand r, HeaderSpec line, {required HeaderSpec? next}) {
  if (!line.isTag || !r.chance(20)) return line;
  final shares = next == null || next.isTag;
  final trailer = shares && r.nextBool() ? ' ' : r.pick(const [' \n', '\t\n']);
  return HeaderSpec.tag(
    line.key!,
    line.value!,
    raw: line.raw,
    trailer: trailer,
  );
}

Iterable<ChapterSpec> _shrunkChapter(ChapterSpec c) sync* {
  final games = c.games;
  if (games.length > 1) {
    for (var i = 0; i < games.length; i++) {
      yield c.copyWith(games: [...games]..removeAt(i));
    }
  }
  if (c.bom) yield c.copyWith(bom: false);
  if (c.preamble.isNotEmpty) yield c.copyWith(preamble: const []);
  if (c.newlines != Newlines.lf) yield c.copyWith(newlines: Newlines.lf);
  if (c.width != 1000) yield c.copyWith(width: 1000);
  for (var i = 0; i < games.length; i++) {
    for (final smaller in _shrunkGame(games[i])) {
      yield c.copyWith(games: [...games]..[i] = smaller);
    }
  }
}

Iterable<ChapterGame> _shrunkGame(ChapterGame g) sync* {
  if (g.illegalAt != null) {
    yield g.copyWith(dropIllegal: true);
    return;
  }
  if (g.escapeLine) yield g.copyWith(escapeLine: false);
  final tree = g.tree;
  if (tree.isEmpty) return;
  yield g.copyWith(
    tree: GameTree(rootFen: tree.rootFen, rootComment: tree.rootComment),
  );
  final main = tree.children.first;
  if (tree.children.length > 1) {
    yield g.copyWith(tree: _withChildren(tree, [main]));
  }
  if (main.children.isNotEmpty) {
    yield g.copyWith(
      tree: _withChildren(tree, [main.copyWith(children: const [])]),
    );
  }
}

GameTree _withChildren(GameTree tree, List<MoveNode> children) => GameTree(
  rootFen: tree.rootFen,
  rootComment: tree.rootComment,
  children: children,
);

/// One game per line: a study's bracketed variations, expanded at import.
///
/// A repertoire chapter is read as one trainable line per PGN game, and
/// every reader of a chapter — the trainer, the builder's line list, the
/// line ids that training progress is keyed by — walks each game's mainline
/// only. An imported study keeps most of its theory in brackets, so importing
/// it as written trained the mainline of each chapter and silently dropped
/// the rest. (The deviation walker reads whole trees, which is how a move
/// could be "in the book" on the games list yet never come up in training.)
///
/// So the import writes each root-to-leaf path of a game as its own game.
/// Done once, at import, the file on disk is exactly what every reader
/// expects and no reader needs to learn about variations. Both places that
/// create a repertoire from PGN go through [createRepertoire], which calls
/// [expandVariationsIntoLines]; so does adding PGN to an existing chapter.
///
/// Games with no variations are copied through untouched, so a file that was
/// already one-game-per-line is written byte for byte as it came.
library;

import 'package:chess_auto_prep/chess_core/pgn/pgn_parser.dart';
import 'package:dartchess/dartchess.dart';

import '../../models/repertoire_line.dart' show isModelGameHeaders;
import '../../utils/fen_utils.dart' show plyFromFen;
import '../../utils/movetext_builder.dart' show formatMoveAtPly;
import 'pgn_text.dart' as pgn;
import 'repertoire_line_ids.dart' show RepertoireLineIds;
import 'course_chapter_headers.dart';

/// [pgn] rewritten so that no game has a variation, and how many games it
/// holds afterwards.
typedef ExpandedPgn = ({String pgn, int gameCount});

/// Header written on every expanded sideline: the plies at which it left the
/// first-child path, space-separated, 0-based from the game's start.
const String kBranchPliesHeader = 'BranchPlies';

/// The headers [courseChapterHeaderKey] reads off each game's text.
const List<String> _chapterKeyHeaders = ['Event', 'White', 'Black', 'Result'];

/// Header values the parser names nothing after, plus the synthetic Event
/// that header-less text is given; never suffixed with a branch label.
const Set<String> _placeholderTitles = {
  '',
  '?',
  'me',
  'opponent',
  'white',
  'black',
  'n.n.',
  'repertoire line',
  'edited line',
};

/// Rewrite [pgnContent] with every variation of every game as a separate
/// game, in reading order: the mainline first, then each sideline where it
/// branches, deepest-first the way the brackets nest.
///
/// A line keeps its game's headers, its comments and glyphs, and the text
/// before the first move. Only the mainline keeps a `LineID`-style header,
/// so training progress saved against the original game still finds it; the
/// sidelines get fresh move-derived ids from the parser. Their naming
/// headers (`Event`, `Opening`, and a Chessable-style `Black` title) are
/// suffixed with the move that leaves the mainline, so twelve lines from one
/// chapter are not twelve rows with the same name.
///
/// A sideline also records *where* it branched, as a [kBranchPliesHeader]
/// header: the 0-based plies (from the game's start position) at which the
/// path took a bracketed move instead of the mainline one. Once the brackets
/// are gone that is the only trace of who the alternative belonged to, and
/// readers need it: in a course export a bracket at the *opponent's* move is
/// coverage ("if 4...Nd7 then …"), while a bracket at *our* move is the
/// author mentioning a move they do not recommend ("3.e5 is the Advance,
/// not covered here"). See `RepertoireLine.branchesOnSide`.
///
/// A complete game — one with a real result, or this app's own model-game
/// tags — is left whole: its brackets are annotation, not repertoire, and
/// the trainer already skips it. A game that fails to parse is copied
/// through as is.
///
/// Returns [pgnContent] itself, untouched, when nothing needed expanding.
ExpandedPgn expandVariationsIntoLines(String pgnContent) {
  final content = pgn.stripBom(pgnContent);
  final games = pgn.splitPgnIntoGames(content);
  if (games.isEmpty) return (pgn: pgnContent, gameCount: 0);

  // Which player header names the *line* (the one that is not the chapter,
  // in a chapter-titled export) — that is the header a sideline's branch
  // label goes on. Suffixing the chapter header instead gave every sideline
  // a chapter of its own.
  final chapterKey = courseChapterHeaderKey(games);
  final titleKey = titleHeaderKeyFor(chapterKey);

  final out = _GameWriter(titleKey);
  var expanded = false;
  for (final text in games) {
    final lines = _expandGame(text, titleKey, chapterKey);
    if (lines == null) {
      out.keep(text);
      continue;
    }
    expanded = true;
    lines.forEach(out.keep);
  }
  if (!expanded && !out.droppedDuplicate) {
    return (pgn: pgnContent, gameCount: out.count);
  }

  // Text before the first game (the app's own `// Color:` header lines, for
  // one) is not part of any chunk; keep it in front.
  final firstAt = content.indexOf(games.first);
  final preamble = firstAt > 0 ? content.substring(0, firstAt) : '';
  return (pgn: '$preamble${out.text}', gameCount: out.count);
}

/// Accumulates games one per block, blank line between them, dropping a
/// game that repeats an earlier one's title and moves.
///
/// A line that appears twice with the same title and the same moves is
/// one line. One course export listed each of its 24 lines under every
/// one of its 24 chapter titles — 576 games to train, 24 to know.
class _GameWriter {
  _GameWriter(this.titleKey);

  final String titleKey;
  final StringBuffer _out = StringBuffer();
  final Set<String> _seen = {};

  /// Games written so far.
  int count = 0;

  /// Whether any game was dropped as a duplicate.
  bool droppedDuplicate = false;

  // Games are separated by a blank line; a verbatim chunk usually brings its
  // own, a rewritten one never does.
  bool _endsWithBlank = true;

  String get text => _out.toString();

  void keep(String piece) {
    if (!_seen.add(_identity(piece, titleKey))) {
      droppedDuplicate = true;
      return;
    }
    if (!_endsWithBlank) _out.write('\n');
    _out.write(piece);
    if (!piece.endsWith('\n')) _out.write('\n');
    _endsWithBlank = piece.endsWith('\n\n');
    count++;
  }
}

/// What makes two games the same line: the title header and the movetext,
/// whitespace collapsed. Other headers (a chapter title, an id) are what a
/// duplicate export varies, so they are left out on purpose.
String _identity(String gameText, String titleKey) {
  final title = _headerValue(gameText, titleKey);
  final movetext = gameText
      .replaceAll(RegExp(r'^\[[^\]]*\]\s*$', multiLine: true), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return '$title\u0000$movetext';
}

/// The value of the `[key "..."]` header in [gameText], read off the text.
String? _headerValue(String gameText, String key) => RegExp(
  '^\\[$key "([^"]*)"\\]',
  multiLine: true,
).firstMatch(gameText)?.group(1);

/// The player header carrying a course export's chapter titles — `White`
/// or `Black` — or null when [games] do not group by one (see
/// `RepertoireService.chapterHeaderKey`). Reads the four headers it needs
/// off each game's text rather than parsing the games.
String? courseChapterHeaderKey(List<String> games) {
  final headersPerGame = [
    for (final text in games)
      {for (final key in _chapterKeyHeaders) key: ?_headerValue(text, key)},
  ];
  return chapterHeaderKey(headersPerGame);
}

/// The games [text] expands to, or null when it should be copied through.
List<String>? _expandGame(String text, String titleKey, String? chapterKey) {
  final PgnGame<PgnNodeData> game;
  try {
    game = parsePgnGame(text, initHeaders: PgnGame.emptyHeaders);
  } catch (_) {
    // Unparseable text is not this function's to judge; it is copied through.
    return null;
  }
  if (!_hasVariation(game.moves)) return null;
  if (isModelGameHeaders(game.headers)) return null;
  final result = (game.headers['Result'] ?? '*').trim();
  if (result.isNotEmpty && result != '*') return null;

  final fen = game.headers['FEN']?.trim();
  final startPly = fen == null || fen.isEmpty ? 0 : plyFromFen(fen);

  return [
    for (final (i, path) in _leafPaths(game.moves).indexed)
      PgnGame<PgnNodeData>(
        headers: i == 0
            ? Map.of(game.headers)
            : _sidelineHeaders(
                game.headers,
                path: path,
                branchPlies: _branchPlies(game.moves, path),
                startPly: startPly,
                titleKey: titleKey,
                chapterKey: chapterKey,
              ),
        moves: _singleLine(path),
        comments: game.comments,
      ).makePgn(),
  ];
}

/// Every root-to-leaf path of [root], in reading order: first children
/// first, the way the brackets nest.
List<List<PgnChildNode<PgnNodeData>>> _leafPaths(PgnNode<PgnNodeData> root) {
  final paths = <List<PgnChildNode<PgnNodeData>>>[];
  void walk(PgnNode<PgnNodeData> node, List<PgnChildNode<PgnNodeData>> acc) {
    if (node.children.isEmpty) {
      paths.add(acc);
      return;
    }
    for (final child in node.children) {
      walk(child, [...acc, child]);
    }
  }

  walk(root, const []);
  return paths;
}

/// A fresh move tree holding only [path], each node's data shared with the
/// original.
PgnNode<PgnNodeData> _singleLine(List<PgnChildNode<PgnNodeData>> path) {
  final root = PgnNode<PgnNodeData>();
  PgnNode<PgnNodeData> tail = root;
  for (final node in path) {
    final copy = PgnChildNode<PgnNodeData>(node.data);
    tail.children.add(copy);
    tail = copy;
  }
  return root;
}

/// A sideline's headers: the game's own minus any line id, with the naming
/// headers suffixed by the move where it last left the mainline and the
/// [kBranchPliesHeader] recording every branch point.
Map<String, String> _sidelineHeaders(
  Map<String, String> gameHeaders, {
  required List<PgnChildNode<PgnNodeData>> path,
  required List<int> branchPlies,
  required int startPly,
  required String titleKey,
  required String? chapterKey,
}) {
  final headers = Map<String, String>.of(gameHeaders);
  for (final key in RepertoireLineIds.headerKeys) {
    headers.remove(key);
  }
  if (branchPlies.isEmpty) return headers;

  // The deepest branch is where this line last left the mainline, e.g.
  // "5...Nf6"; that move is what names it.
  final branchPly = branchPlies.last;
  _suffixNamingHeaders(
    headers,
    formatMoveAtPly(
      startPly + branchPly,
      path[branchPly].data.san,
      compact: true,
    ),
    titleKey,
    chapterKey,
  );
  headers[kBranchPliesHeader] = branchPlies.join(' ');
  return headers;
}

bool _hasVariation(PgnNode<PgnNodeData> node) {
  var current = node;
  while (current.children.isNotEmpty) {
    if (current.children.length > 1) return true;
    current = current.children.first;
  }
  return false;
}

/// Every ply on [path] where it took a move other than its parent's first
/// child, counted from the game's start position (not the initial position:
/// a line from a FEN counts from that FEN).
List<int> _branchPlies(
  PgnNode<PgnNodeData> root,
  List<PgnChildNode<PgnNodeData>> path,
) {
  PgnNode<PgnNodeData> parent = root;
  final plies = <int>[];
  for (var ply = 0; ply < path.length; ply++) {
    final node = path[ply];
    if (parent.children.first != node) plies.add(ply);
    parent = node;
  }
  return plies;
}

void _suffixNamingHeaders(
  Map<String, String> headers,
  String label,
  String titleKey,
  String? chapterKey,
) {
  // Never the chapter header: a suffix there makes every sideline a chapter
  // of its own.
  for (final key in {'Event', 'Opening', titleKey}.difference({chapterKey})) {
    final value = headers[key]?.trim();
    if (value == null || _placeholderTitles.contains(value.toLowerCase())) {
      continue;
    }
    headers[key] = '$value — $label';
  }
}

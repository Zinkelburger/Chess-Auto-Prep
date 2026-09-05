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

import 'package:dartchess/dartchess.dart';

import '../models/repertoire_line.dart' show isModelGameHeaders;
import '../utils/fen_utils.dart' show plyFromFen;
import '../utils/movetext_builder.dart' show formatMoveAtPly;
import 'pgn_parsing_service.dart' as pgn;
import 'repertoire_line_ids.dart' show RepertoireLineIds;

/// [pgn] rewritten so that no game has a variation, and how many games it
/// holds afterwards.
typedef ExpandedPgn = ({String pgn, int gameCount});

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

  final out = StringBuffer();
  var count = 0;
  var expanded = false;
  // Games are separated by a blank line; a verbatim chunk usually brings its
  // own, a rewritten one never does.
  var endsWithBlank = true;
  void add(String piece) {
    if (!endsWithBlank) out.write('\n');
    out.write(piece);
    if (!piece.endsWith('\n')) out.write('\n');
    endsWithBlank = piece.endsWith('\n\n');
  }

  for (final text in games) {
    final lines = _expandGame(text);
    if (lines == null) {
      add(text);
      count++;
      continue;
    }
    expanded = true;
    lines.forEach(add);
    count += lines.length;
  }
  if (!expanded) return (pgn: pgnContent, gameCount: count);

  // Text before the first game (the app's own `// Color:` header lines, for
  // one) is not part of any chunk; keep it in front.
  final firstAt = content.indexOf(games.first);
  final preamble = firstAt > 0 ? content.substring(0, firstAt) : '';
  return (pgn: '$preamble$out', gameCount: count);
}

/// The games [text] expands to, or null when it should be copied through.
List<String>? _expandGame(String text) {
  final PgnGame<PgnNodeData> game;
  try {
    game = PgnGame.parsePgn(text, initHeaders: PgnGame.emptyHeaders);
  } catch (_) {
    return null;
  }
  if (!_hasVariation(game.moves)) return null;
  if (isModelGameHeaders(game.headers)) return null;
  final result = (game.headers['Result'] ?? '*').trim();
  if (result.isNotEmpty && result != '*') return null;

  final fen = game.headers['FEN']?.trim();
  final startPly = fen == null || fen.isEmpty ? 0 : plyFromFen(fen);

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

  walk(game.moves, const []);

  final lines = <String>[];
  for (var i = 0; i < paths.length; i++) {
    final path = paths[i];
    final root = PgnNode<PgnNodeData>();
    PgnNode<PgnNodeData> tail = root;
    for (final node in path) {
      final copy = PgnChildNode<PgnNodeData>(node.data);
      tail.children.add(copy);
      tail = copy;
    }
    final headers = Map<String, String>.of(game.headers);
    if (i > 0) {
      for (final key in RepertoireLineIds.headerKeys) {
        headers.remove(key);
      }
      final label = _branchLabel(game.moves, path, startPly);
      if (label != null) _suffixNamingHeaders(headers, label);
    }
    lines.add(
      PgnGame<PgnNodeData>(
        headers: headers,
        moves: root,
        comments: game.comments,
      ).makePgn(),
    );
  }
  return lines;
}

bool _hasVariation(PgnNode<PgnNodeData> node) {
  var current = node;
  while (current.children.isNotEmpty) {
    if (current.children.length > 1) return true;
    current = current.children.first;
  }
  return false;
}

/// The deepest move on [path] that is not its parent's first child: where
/// this line last left the mainline, e.g. "5...Nf6". Null for the mainline.
String? _branchLabel(
  PgnNode<PgnNodeData> root,
  List<PgnChildNode<PgnNodeData>> path,
  int startPly,
) {
  PgnNode<PgnNodeData> parent = root;
  String? label;
  for (var ply = 0; ply < path.length; ply++) {
    final node = path[ply];
    if (parent.children.first != node) {
      label = formatMoveAtPly(startPly + ply, node.data.san, compact: true);
    }
    parent = node;
  }
  return label;
}

void _suffixNamingHeaders(Map<String, String> headers, String label) {
  // The placeholders the parser names nothing after, plus the synthetic
  // Event that header-less text is given.
  const ignored = {
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
  for (final key in const ['Event', 'Opening', 'Black']) {
    final value = headers[key]?.trim();
    if (value == null || ignored.contains(value.toLowerCase())) continue;
    headers[key] = '$value — $label';
  }
}

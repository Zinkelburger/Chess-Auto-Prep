import 'package:dartchess/dartchess.dart' show Side;

import '../fen.dart';
import '../position_setup.dart';
import 'chapter.dart';
import 'game_text.dart';
import 'pgn_reader.dart';
import 'tree_edit.dart';

/// The analysis board as a document: a chapter no file holds.
///
/// It is an ordinary merged chapter, so the board, the move list, the
/// comment field and every edit work on it unchanged; only where it lives
/// differs. The text is built here and read back by [parseChapter], so the
/// tree is the kind every other chapter has. The `// Color:` line is the
/// side the board is played from, which is also the side a generation from
/// it prepares for.

/// What the analysis board is called wherever a chapter's name is shown.
const analysisBoardName = 'Analysis';

/// An analysis board from [root] with [sans] played, as far as they can be.
/// A board that starts at the start with no moves holds no game yet; one
/// from another position holds one game with no moves, whose `[FEN]` is
/// where the board starts.
Chapter analysisBoard({
  required Side side,
  Fen root = Fen.initial,
  List<String> sans = const [],
}) {
  if (root == Fen.initial && sans.isEmpty) return _chapterOf(side, '');
  final tree = lineTree(root, sans);
  final tags = [
    const PgnTag('Event', analysisBoardName),
    const PgnTag('Result', '*'),
    if (root != Fen.initial) ...[
      PgnTag('FEN', root.value),
      const PgnTag('SetUp', '1'),
    ],
  ];
  return _chapterOf(
    side,
    writeGameText(tags, tree, terminator: '*', separator: '\n'),
  );
}

/// What pasting [text] onto the analysis board made of it.
sealed class Pasted {
  const Pasted();
}

final class PastedBoard extends Pasted {
  const PastedBoard(this.chapter);

  final Chapter chapter;
}

final class PasteRefused extends Pasted {
  const PasteRefused(this.reason);

  /// A sentence for the screen.
  final String reason;
}

/// [text] as an analysis board: a FEN, at that position and seen from the
/// side to move; a PGN — its first game, variations and comments included —
/// or bare moves such as `1.e4 c5 2.Nf3`, played from [side], or from the
/// side to move when the game starts from a position of its own. Text that
/// holds no position and no move is refused rather than shown as an empty
/// board, which would look like a paste that worked.
Pasted pastedBoard(String text, {required Side side}) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) {
    return const PasteRefused('Nothing to paste: copy a PGN or FEN first.');
  }
  if (_fenFields(trimmed) != null) return pastedPosition(trimmed);
  final games = splitChapterText(trimmed).games;
  // A file is cut into games at their `[Event` lines, so moves pasted with
  // no header, or a header without that tag, are given one to be a game.
  final game = games.isEmpty
      ? '[Event "$analysisBoardName"]\n'
            '${trimmed.startsWith('[') ? '' : '\n'}$trimmed'
      : games.first.text;
  final read = readGame(game);
  final tree = read.tree;
  if (tree == null || (tree.children.isEmpty && tree.rootFen == Fen.initial)) {
    final why = read.issues.firstOrNull?.detail;
    return PasteRefused(
      why == null
          ? 'The clipboard holds no PGN or FEN.'
          : 'The clipboard holds no game that can be read: $why.',
    );
  }
  final facing = tree.rootFen == Fen.initial ? side : _toMove(tree.rootFen);
  // Moves after the first one that cannot be read are dropped, as a chapter
  // would drop them; the board shows what could be played, from the game's
  // own start, so the rest of the text is never half-shown.
  if (read.issues.isNotEmpty) {
    return PastedBoard(
      analysisBoard(side: facing, root: tree.rootFen, sans: mainlineSans(tree)),
    );
  }
  return PastedBoard(_chapterOf(facing, game));
}

/// [text] as an analysis board at the position it holds, seen from the
/// side to move, when it is one FEN and nothing else: what Ctrl+Shift+V
/// pastes.
Pasted pastedPosition(String text) {
  if (text.trim().isEmpty) {
    return const PasteRefused('Nothing to paste: copy a FEN first.');
  }
  final fen = pastedFen(text);
  if (fen != null) {
    return PastedBoard(analysisBoard(side: _toMove(fen), root: fen));
  }
  final fields = _fenFields(text);
  final cause = fields == null
      ? null
      : SetupEdits.read(fields.join(' '))?.illegal;
  return PasteRefused(switch (cause) {
    final cause? => 'Not a playable FEN. ${illegalSetupReason(cause)}',
    null when fields != null => 'That FEN cannot be read.',
    null => 'The clipboard holds no FEN.',
  });
}

/// [text] as a position a game can start from, when it is one FEN and
/// nothing else. It may be quoted, or a PGN's `[FEN "…"]` tag, and may stop
/// after any field: the side to move is then White, the castling rights
/// and the en-passant square none, the counters 0 and 1. Rights the board
/// does not allow are dropped.
Fen? pastedFen(String text) {
  final fields = _fenFields(text);
  return fields == null ? null : playableFen(fields.join(' '));
}

/// The fields of the one FEN [text] holds — its board has eight ranks — or
/// null when it holds anything else.
List<String>? _fenFields(String text) {
  var fen = text.trim();
  if (_fenTag.firstMatch(fen) case final tag?) fen = tag.group(1)!;
  fen = _unquoted(fen.trim());
  if (fen.contains('\n')) return null;
  final fields = fen.split(RegExp(r'\s+'));
  if (fields.length > 6 || '/'.allMatches(fields.first).length != 7) {
    return null;
  }
  return [
    fields.first,
    if (fields.length > 1) fields[1].toLowerCase(),
    ...fields.skip(2),
  ];
}

final _fenTag = RegExp(r'^\[FEN\s+"([^"]*)"\]$');

const _quotes = {'"': '"', "'": "'", '`': '`', '\u201c': '\u201d'};

String _unquoted(String text) {
  var inner = text;
  while (inner.length > 1) {
    final close = _quotes[inner[0]];
    if (close == null || !inner.endsWith(close)) break;
    inner = inner.substring(1, inner.length - 1).trim();
  }
  return inner;
}

Side _toMove(Fen fen) => fen.whiteToMove ? Side.white : Side.black;

Chapter _chapterOf(Side side, String game) => parseChapter(
  name: analysisBoardName,
  text:
      '// Color: ${side == Side.white ? 'White' : 'Black'}\n\n'
      '${game.isEmpty ? '' : '$game\n'}',
);

import 'package:dartchess/dartchess.dart' show Side;

import '../fen.dart';
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
const analysisBoardName = 'Analysis board';

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

/// [text] as an analysis board played from [side]: a FEN, a PGN — its first
/// game, variations and comments included — or bare moves such as
/// `1.e4 c5 2.Nf3`. Text that holds no position and no move is refused
/// rather than shown as an empty board, which would look like a paste that
/// worked.
Pasted pastedBoard(String text, {required Side side}) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) {
    return const PasteRefused('Nothing to paste: copy a PGN or FEN first.');
  }
  if (pastedPosition(trimmed, side: side) case final PastedBoard board) {
    return board;
  }
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
  // Moves after the first one that cannot be read are dropped, as a chapter
  // would drop them; the board shows what could be played, from the game's
  // own start, so the rest of the text is never half-shown.
  if (read.issues.isNotEmpty) {
    return PastedBoard(
      analysisBoard(side: side, root: tree.rootFen, sans: mainlineSans(tree)),
    );
  }
  return PastedBoard(_chapterOf(side, game));
}

/// [text] as an analysis board at the position it holds, played from
/// [side], when it is one FEN and nothing else: what Ctrl+Shift+V pastes.
Pasted pastedPosition(String text, {required Side side}) {
  final fen = _asFen(text.trim());
  if (fen == null) return const PasteRefused('The clipboard holds no FEN.');
  return PastedBoard(analysisBoard(side: side, root: fen));
}

/// [text] as a position when it is one FEN and nothing else.
Fen? _asFen(String text) {
  if (!text.contains('/') || text.contains('\n')) return null;
  final fields = text.split(RegExp(r'\s+'));
  if (fields.length < 4 || fields.length > 6) return null;
  // A FEN without its two counters is still a position; they are filled in
  // so the board and every cache see the six fields they expect.
  final fen = Fen(
    [
      ...fields,
      if (fields.length < 5) '0',
      if (fields.length < 6) '1',
    ].join(' '),
  );
  return positionOf(fen) == null ? null : fen;
}

Chapter _chapterOf(Side side, String game) => parseChapter(
  name: analysisBoardName,
  text:
      '// Color: ${side == Side.white ? 'White' : 'Black'}\n\n'
      '${game.isEmpty ? '' : '$game\n'}',
);

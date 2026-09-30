import 'package:flutter/widgets.dart';

/// How moves are written on screen: letters (`Nf3`) or figurines (`♘f3`),
/// the user's choice for the whole window.
///
/// Only the pixels change. Everything that is stored, compared, copied or
/// parsed back — the PGN, the move box, a copied line — keeps the letters,
/// so every widget that shows a move passes its text through [displaySan]
/// at the last moment and nowhere else.
class MoveNotation extends InheritedWidget {
  const MoveNotation({
    super.key,
    required this.figurines,
    required super.child,
  });

  final bool figurines;

  @override
  bool updateShouldNotify(MoveNotation oldWidget) =>
      oldWidget.figurines != figurines;
}

/// [text] — one move, a numbered line or a label with moves in it — as the
/// user has chosen to see moves, and redrawn when they choose again. Outside
/// a [MoveNotation] (a test of one widget) moves keep their letters.
String displaySan(BuildContext context, String text) {
  final notation = context.dependOnInheritedWidgetOfExactType<MoveNotation>();
  return notation?.figurines ?? false ? figurineSan(text) : text;
}

/// White figurines for both sides, the way printed chess books set them.
const _figurines = {'K': '♔', 'Q': '♕', 'R': '♖', 'B': '♗', 'N': '♘'};

/// Every move in [text] with its piece letter drawn as a figurine: `Nf3` →
/// `♘f3`, `12...Bxd7+` → `12...♗xd7+`, `exd8=Q` → `exd8=♕`, a bughouse
/// drop `N@f3` → `♘@f3`. Castling and
/// pawn moves have no piece letter and stay as written.
///
/// A letter is changed only where it starts a whole SAN move — a piece
/// letter, an optional origin file or rank, an optional capture and a
/// destination square, not glued to a letter before it — or follows a
/// promotion `=`, so prose around the moves (`Book ends after Nf3`, `Bad`)
/// keeps its capitals.
String figurineSan(String text) =>
    text.replaceAllMapped(_pieceLetter, (m) => _figurines[m[0]]!);

final _pieceLetter = RegExp(
  r'(?<![A-Za-z])[KQRBN](?=[a-h]?[1-8]?x?[a-h][1-8]|@[a-h][1-8])'
  r'|(?<=[a-h][18]=)[QRBN]',
);

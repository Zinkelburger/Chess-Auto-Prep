/// State owner for the board editor: free piece placement, side to move,
/// castling rights, en passant, and FEN in/out.
///
/// Unlike the play board, nothing here is constrained by legal moves; the
/// only gate is [validPosition], which runs dartchess's full setup
/// validation before a position leaves the editor.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

import '../utils/safe_change_notifier.dart';
import '../utils/chess_utils.dart';

/// What the pointer does on an editor board — the lichess editor's model,
/// shared by every board editor in the app (the standard one and bughouse).
///
/// The pointer is the resting state: pieces are dragged around, and nothing
/// happens on a bare click. A [PieceBrush] paints one piece; the [EraserTool]
/// paints emptiness. Both act on press and keep acting while the button is
/// held and the pointer crosses squares, so a rank of pawns is one stroke.
sealed class EditorTool {
  const EditorTool();
}

/// Move pieces by dragging; a drop off the board removes the piece.
class PointerTool extends EditorTool {
  const PointerTool();

  @override
  bool operator ==(Object other) => other is PointerTool;

  @override
  int get hashCode => (PointerTool).hashCode;
}

/// Place [piece] on pressed squares (pressing the same piece removes it).
class PieceBrush extends EditorTool {
  final Piece piece;
  const PieceBrush(this.piece);

  /// The same piece in the other colour — what a right-click switches to.
  PieceBrush get flipped =>
      PieceBrush(Piece(color: piece.color.opposite, role: piece.role));

  @override
  bool operator ==(Object other) => other is PieceBrush && other.piece == piece;

  @override
  int get hashCode => Object.hash(PieceBrush, piece);
}

/// Remove pieces from pressed squares.
class EraserTool extends EditorTool {
  const EraserTool();

  @override
  bool operator ==(Object other) => other is EraserTool;

  @override
  int get hashCode => (EraserTool).hashCode;
}

class BoardEditorController extends ChangeNotifier with SafeChangeNotifier {
  BoardEditorController({String? initialFen}) {
    if (initialFen == null || !loadFen(initialFen)) {
      setStartPosition();
    }
  }

  /// dartchess [Board] is immutable; every mutation swaps in a new one.
  Board _board = Board.standard;
  Board get board => _board;

  Side _turn = Side.white;
  Side get turn => _turn;

  // Desired castling rights (as toggled by the user or loaded from FEN).
  // The *effective* rights are clamped to what the piece placement allows —
  // see [whiteKingsideAllowed] etc. — so stale flags never poison the FEN.
  bool _whiteKingside = true;
  bool _whiteQueenside = true;
  bool _blackKingside = true;
  bool _blackQueenside = true;

  Square? _epSquare;

  // Move counters are carried through from a loaded FEN so a position pasted
  // from a real game keeps its move number ("Move 23, White to play").
  int _halfmoves = 0;
  int _fullmoves = 1;

  String? _fenDraft;

  /// Text being edited, or the current board FEN when there is no draft.
  String get fenInput => _fenDraft ?? fen;

  /// A caller must apply or discard the text before using this position.
  /// Changes to the draft notify listeners just like board edits.
  bool get hasUnappliedFen => _fenDraft != null;

  void setFenDraft(String value) {
    final draft = value == fen ? null : value;
    if (draft == _fenDraft) return;
    _fenDraft = draft;
    notifyListeners();
  }

  void discardFenDraft() {
    if (_fenDraft == null) return;
    _fenDraft = null;
    notifyListeners();
  }

  EditorTool _tool = const PointerTool();
  EditorTool get tool => _tool;

  /// Board orientation: `true` shows Black at the bottom.
  bool _flipped = false;
  bool get flipped => _flipped;

  // ── Piece placement ──────────────────────────────────────────────────

  Piece? pieceAt(Square square) => _board.pieceAt(square);

  void setPiece(Square square, Piece piece) {
    _board = _board.setPieceAt(square, piece);
    _afterBoardChange();
  }

  void removePiece(Square square) {
    if (_board.pieceAt(square) == null) return;
    _board = _board.removePieceAt(square);
    _afterBoardChange();
  }

  void movePiece(Square from, Square to) {
    final piece = _board.pieceAt(from);
    if (piece == null || from == to) return;
    _board = _board.removePieceAt(from).setPieceAt(to, piece);
    _afterBoardChange();
  }

  /// A press on [square] with the active tool: the brush places its piece
  /// (pressing a square that already holds that piece removes it), the
  /// eraser clears the square, and the pointer does nothing — it moves
  /// pieces by dragging instead.
  void pressSquare(Square square) {
    switch (_tool) {
      case PieceBrush(:final piece):
        if (_board.pieceAt(square) == piece) {
          removePiece(square);
        } else {
          setPiece(square, piece);
        }
      case EraserTool():
        removePiece(square);
      case PointerTool():
        break;
    }
  }

  /// The pointer crossed onto [square] with the button still held: keep
  /// painting with the active tool. Unlike [pressSquare] this never toggles,
  /// so a stroke across a rank fills every square it touches.
  void paintSquare(Square square) {
    switch (_tool) {
      case PieceBrush(:final piece):
        if (_board.pieceAt(square) != piece) setPiece(square, piece);
      case EraserTool():
        removePiece(square);
      case PointerTool():
        break;
    }
  }

  /// A right-click on [square]: with a brush in hand it swaps the brush to
  /// the other colour (lichess' shortcut for setting up both sides without
  /// walking back to the palette); otherwise it clears the square.
  void secondaryPressSquare(Square square) {
    switch (_tool) {
      case PieceBrush():
        flipBrushColour();
      case EraserTool() || PointerTool():
        removePiece(square);
    }
  }

  void flipBrushColour() {
    if (_tool case PieceBrush(:final flipped)) selectTool(flipped);
  }

  void selectTool(EditorTool tool) {
    if (tool == _tool) return;
    _tool = tool;
    notifyListeners();
  }

  void toggleFlip() {
    _flipped = !_flipped;
    notifyListeners();
  }

  void clear() {
    _board = Board.empty;
    _afterBoardChange();
  }

  void setStartPosition() {
    _fenDraft = null;
    _board = Board.standard;
    _turn = Side.white;
    _whiteKingside = true;
    _whiteQueenside = true;
    _blackKingside = true;
    _blackQueenside = true;
    _epSquare = null;
    _halfmoves = 0;
    _fullmoves = 1;
    notifyListeners();
  }

  void _afterBoardChange() {
    // Clamp en passant: the candidate list is derived from the board, so a
    // placement change can invalidate the current choice.
    if (_epSquare != null && !epCandidates.contains(_epSquare)) {
      _epSquare = null;
    }
    notifyListeners();
  }

  // ── Side to move ─────────────────────────────────────────────────────

  void setTurn(Side side) {
    if (side == _turn) return;
    _turn = side;
    // En passant candidates depend on whose move it is.
    if (_epSquare != null && !epCandidates.contains(_epSquare)) {
      _epSquare = null;
    }
    notifyListeners();
  }

  // ── Castling rights ──────────────────────────────────────────────────
  //
  // A right is *allowed* iff the king and the relevant rook stand on their
  // home squares (standard chess only).  The checkbox state the UI shows is
  // `desired && allowed`; toggling stores the desire so briefly lifting a
  // rook doesn't permanently clear the flag.

  bool _has(Square square, Role role, Side side) {
    final piece = _board.pieceAt(square);
    return piece != null && piece.role == role && piece.color == side;
  }

  bool get whiteKingsideAllowed =>
      _has(Square.e1, Role.king, Side.white) &&
      _has(Square.h1, Role.rook, Side.white);
  bool get whiteQueensideAllowed =>
      _has(Square.e1, Role.king, Side.white) &&
      _has(Square.a1, Role.rook, Side.white);
  bool get blackKingsideAllowed =>
      _has(Square.e8, Role.king, Side.black) &&
      _has(Square.h8, Role.rook, Side.black);
  bool get blackQueensideAllowed =>
      _has(Square.e8, Role.king, Side.black) &&
      _has(Square.a8, Role.rook, Side.black);

  bool get whiteKingside => _whiteKingside && whiteKingsideAllowed;
  bool get whiteQueenside => _whiteQueenside && whiteQueensideAllowed;
  bool get blackKingside => _blackKingside && blackKingsideAllowed;
  bool get blackQueenside => _blackQueenside && blackQueensideAllowed;

  void setWhiteKingside(bool value) {
    _whiteKingside = value;
    notifyListeners();
  }

  void setWhiteQueenside(bool value) {
    _whiteQueenside = value;
    notifyListeners();
  }

  void setBlackKingside(bool value) {
    _blackKingside = value;
    notifyListeners();
  }

  void setBlackQueenside(bool value) {
    _blackQueenside = value;
    notifyListeners();
  }

  // ── En passant ───────────────────────────────────────────────────────

  Square? get epSquare => _epSquare;

  /// Legal en-passant target squares for the current placement + turn.
  ///
  /// White to move → targets on rank 6: an enemy (black) pawn must stand on
  /// the square in front of the target (rank 5) with the target and origin
  /// (rank 7) squares empty.  Black to move → the mirror on rank 3.
  List<Square> get epCandidates {
    final candidates = <Square>[];
    // Rank indices are 0-based: rank 6 == index 5, rank 3 == index 2.
    final targetRank = _turn == Side.white ? 5 : 2;
    final pawnRank = _turn == Side.white ? 4 : 3;
    final originRank = _turn == Side.white ? 6 : 1;
    final enemy = _turn == Side.white ? Side.black : Side.white;

    for (int file = 0; file < 8; file++) {
      final target = Square(targetRank * 8 + file);
      final pawnSq = Square(pawnRank * 8 + file);
      final originSq = Square(originRank * 8 + file);
      if (_has(pawnSq, Role.pawn, enemy) &&
          _board.pieceAt(target) == null &&
          _board.pieceAt(originSq) == null) {
        candidates.add(target);
      }
    }
    return candidates;
  }

  void setEpSquare(Square? square) {
    if (square != null && !epCandidates.contains(square)) return;
    _epSquare = square;
    notifyListeners();
  }

  // ── FEN in/out ───────────────────────────────────────────────────────

  String get _castlingField {
    final buf = StringBuffer();
    if (whiteKingside) buf.write('K');
    if (whiteQueenside) buf.write('Q');
    if (blackKingside) buf.write('k');
    if (blackQueenside) buf.write('q');
    return buf.isEmpty ? '-' : buf.toString();
  }

  /// The full 6-field FEN for the current editor state.
  String get fen {
    final turnField = _turn == Side.white ? 'w' : 'b';
    final epField = _epSquare?.name ?? '-';
    return '${_board.fen} $turnField $_castlingField $epField '
        '$_halfmoves $_fullmoves';
  }

  /// The validated position, or `null` when there is unapplied FEN text or
  /// the setup is illegal (see [validationError]).
  Position? get validPosition => hasUnappliedFen ? null : tryParseFen(fen);

  /// Human-readable reason the current setup is invalid, or `null` when it
  /// is fine.
  String? get validationError {
    try {
      Chess.fromSetup(Setup.parseFen(fen));
      return null;
    } on PositionSetupException catch (e) {
      return switch (e.cause) {
        IllegalSetupCause.empty => 'The board is empty.',
        IllegalSetupCause.kings => 'Each side needs exactly one king.',
        IllegalSetupCause.oppositeCheck => 'The side not to move is in check.',
        IllegalSetupCause.impossibleCheck =>
          'Impossible check: this position cannot be reached.',
        IllegalSetupCause.pawnsOnBackrank =>
          'Pawns cannot stand on the first or last rank.',
        IllegalSetupCause.variant => 'Invalid position.',
      };
    } on FenException catch (e) {
      return 'Invalid FEN (${e.cause.name}).';
    } catch (e) {
      return 'Invalid position: $e';
    }
  }

  /// Load a FEN (4–6 fields, with omitted counters defaulting to 0 and 1).
  /// Returns `false` and leaves the editor
  /// untouched when the string cannot be parsed.  Note: the *placement* may
  /// still be an illegal setup — that is intentional so a user can paste a
  /// work-in-progress FEN and fix it on the board.
  bool loadFen(String input) {
    final fields = input.trim().split(RegExp(r'\s+'));
    if (fields.length < 4 || fields.length > 6) return false;
    try {
      if (!RegExp(r'^[prnbqkPRNBQK1-8/]+$').hasMatch(fields[0])) return false;
      final board = Board.parseFen(fields[0]);
      final turn = switch (fields[1]) {
        'w' => Side.white,
        'b' => Side.black,
        _ => throw const FenException(IllegalFenCause.turn),
      };
      final castling = fields[2];
      if (castling != '-' &&
          (!RegExp(r'^[KQkq]+$').hasMatch(castling) ||
              castling.split('').toSet().length != castling.length)) {
        return false;
      }
      Square? ep;
      if (fields[3] != '-') {
        if (!RegExp(r'^[a-h][36]$').hasMatch(fields[3])) return false;
        ep = Square.parse(fields[3]);
        if (ep == null) throw const FenException(IllegalFenCause.enPassant);
      }
      final halfmoves = fields.length > 4 ? int.tryParse(fields[4]) : 0;
      final fullmoves = fields.length > 5 ? int.tryParse(fields[5]) : 1;
      if ((fields.length > 4 && !RegExp(r'^\d+$').hasMatch(fields[4])) ||
          (fields.length > 5 && !RegExp(r'^\d+$').hasMatch(fields[5])) ||
          halfmoves == null ||
          halfmoves < 0 ||
          fullmoves == null ||
          fullmoves < 1) {
        return false;
      }

      // Commit only after every field has parsed, preserving the old setup
      // when a pasted FEN has malformed metadata.
      _board = board;
      _turn = turn;
      _whiteKingside = castling.contains('K');
      _whiteQueenside = castling.contains('Q');
      _blackKingside = castling.contains('k');
      _blackQueenside = castling.contains('q');
      _epSquare = (ep != null && epCandidates.contains(ep)) ? ep : null;
      _halfmoves = halfmoves;
      _fullmoves = fullmoves;
      _fenDraft = null;
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }
}

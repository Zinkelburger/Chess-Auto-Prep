/// Controls temporary board position previews.
///
/// Any widget can request a preview; at most one is active.
/// [BoardPreviewTarget.mainBoard] updates the committed board pane;
/// [BoardPreviewTarget.floating] drives a mini board overlay (Lichess-style).
library;

import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../utils/chess_utils.dart' show uciHighlightSquares;
import '../utils/safe_change_notifier.dart';

/// Where the active preview is rendered.
enum BoardPreviewTarget { mainBoard, floating }

class BoardPreviewController extends ChangeNotifier with SafeChangeNotifier {
  /// Hover settles before a preview appears, so sweeping the pointer across
  /// a list does not flash every row's position.
  static const Duration previewDelay = Duration(milliseconds: 80);

  String? _previewFen;
  List<String>? _previewMoves;
  BoardPreviewTarget _target = BoardPreviewTarget.mainBoard;
  String? _lastMoveUci;
  Offset? _anchorGlobal;
  Timer? _debounce;

  /// Opaque tag identifying which pane owns the current floating preview.
  /// Each [FloatingBoardPreview] passes its own key and only renders when
  /// the tag matches, preventing duplicate boards across panes.
  Object? _ownerTag;

  String? get previewFen => _previewFen;
  List<String>? get previewMoves => _previewMoves;
  BoardPreviewTarget get target => _target;
  String? get lastMoveUci => _lastMoveUci;
  Offset? get anchorGlobal => _anchorGlobal;
  Object? get ownerTag => _ownerTag;
  bool get isPreview => _previewFen != null;

  Set<String> _hoverSquares = const {};

  /// From/to squares of the move under the pointer in a move list (opening
  /// explorer, repertoire tree, generated candidates), tinted on the
  /// committed board. Empty when nothing is hovered.
  ///
  /// A tint rather than an arrow: the board already answers "which move is
  /// this" with the same two squares it uses for the move you just played,
  /// so a hovered move and a played move read alike instead of introducing
  /// a second vocabulary drawn on top of the pieces.
  Set<String> get hoverSquares => _hoverSquares;

  /// Echo [uci]'s from/to squares, or clear with null. Immediate — a hover
  /// echo that lagged behind the pointer would feel broken, not calm.
  void setHoverMove(String? uci) {
    final next = uci == null ? const <String>{} : uciHighlightSquares(uci);
    if (setEquals(next, _hoverSquares)) return;
    _hoverSquares = next;
    notifyListeners();
  }

  /// Request a board preview. Debounced by [previewDelay].
  ///
  /// [ownerTag] identifies which pane triggered the preview so only its
  /// [FloatingBoardPreview] renders the overlay.
  void setPreview(
    String fen, {
    List<String>? moves,
    BoardPreviewTarget target = BoardPreviewTarget.mainBoard,
    String? lastMoveUci,
    Offset? anchorGlobal,
    Object? ownerTag,
  }) {
    if (anchorGlobal != null) _anchorGlobal = anchorGlobal;

    _debounce?.cancel();
    _debounce = Timer(previewDelay, () {
      if (isDisposed) return;
      _previewFen = fen;
      _previewMoves = moves;
      _target = target;
      _lastMoveUci = lastMoveUci;
      _ownerTag = ownerTag;
      notifyListeners();
    });
  }

  /// Clear the preview (mouse leave). Immediate, no debounce.
  void clearPreview() {
    _debounce?.cancel();
    if (_previewFen == null && _anchorGlobal == null) return;
    _previewFen = null;
    _previewMoves = null;
    _target = BoardPreviewTarget.mainBoard;
    _lastMoveUci = null;
    _anchorGlobal = null;
    _ownerTag = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }
}

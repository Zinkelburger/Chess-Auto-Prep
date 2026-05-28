/// Controls temporary board position previews.
///
/// Any widget can request a preview; at most one is active.
/// [BoardPreviewTarget.mainBoard] updates the committed board pane;
/// [BoardPreviewTarget.floating] drives a mini board overlay (Lichess-style).
library;

import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';

/// Where the active preview is rendered.
enum BoardPreviewTarget {
  mainBoard,
  floating,
}

class BoardPreviewController extends ChangeNotifier {
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

  /// Request a board preview. Debounced at 80ms.
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
    _debounce = Timer(const Duration(milliseconds: 80), () {
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

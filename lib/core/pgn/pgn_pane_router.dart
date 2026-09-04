/// Routes PGN viewer commands to the movetext pane the user can see.
///
/// The Game reader has extra screen-level semantics (opening-tree and
/// solitaire modes), so its commands stay callbacks. The Book reader is a
/// plain [PgnViewerHandle] and can be driven directly. Keeping this decision
/// here prevents individual buttons and shortcuts from drifting apart.
library;

import 'package:flutter/foundation.dart';

import 'pgn_viewer_handle.dart';

class PgnPaneRouter {
  const PgnPaneRouter({
    required this.game,
    required this.book,
    required this.isBookActive,
    required this.onGameBoardMove,
  });

  final PgnViewerHandle game;
  final PgnViewerHandle book;
  final bool Function() isBookActive;
  final ValueChanged<String> onGameBoardMove;

  PgnViewerHandle get active => isBookActive() ? book : game;

  void playBoardMove(String san) {
    if (isBookActive()) {
      book.addEphemeralMove(san);
    } else {
      onGameBoardMove(san);
    }
  }

  void goBack(VoidCallback onGame) {
    if (isBookActive()) {
      book.goBack();
    } else {
      onGame();
    }
  }

  void goForward(VoidCallback onGame) {
    if (isBookActive()) {
      book.goForward();
    } else {
      onGame();
    }
  }

  void goToStart(VoidCallback onGame) {
    if (isBookActive()) {
      book.goToMainLineIndex(0);
    } else {
      onGame();
    }
  }

  void goToEnd(VoidCallback onGame) {
    if (isBookActive()) {
      book.goToMainLineIndex(book.mainLineLength);
    } else {
      onGame();
    }
  }
}

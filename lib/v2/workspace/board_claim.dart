import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/foundation.dart';

import '../chess/fen.dart';

/// A position another owner puts on the workspace's board in place of the
/// document's, for as long as it holds the claim: a lesson drilling a line
/// the board must not give away. While one is held the board shows only
/// it, and nothing under the board speaks of the document.
final class BoardClaim {
  const BoardClaim({
    required this.fen,
    required this.orientation,
    required this.onMove,
    this.lastMove,
  });

  final Fen fen;
  final Side orientation;

  /// The move played on the board, as UCI; null while no move is wanted,
  /// which leaves the pieces where they are.
  final void Function(String uci)? onMove;

  /// The move that reached [fen], as UCI, for the highlight.
  final String? lastMove;
}

/// The first of several owners' claims that holds the board: a lesson
/// before the explorer Book's free board, say.
final class FirstClaim extends ChangeNotifier
    implements ValueListenable<BoardClaim?> {
  FirstClaim(this._claims) {
    for (final claim in _claims) {
      claim.addListener(notifyListeners);
    }
  }

  final List<ValueListenable<BoardClaim?>> _claims;

  @override
  BoardClaim? get value =>
      _claims.map((claim) => claim.value).nonNulls.firstOrNull;

  @override
  void dispose() {
    for (final claim in _claims) {
      claim.removeListener(notifyListeners);
    }
    super.dispose();
  }
}

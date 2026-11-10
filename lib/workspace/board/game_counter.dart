import 'package:flutter/material.dart';

import '../../ui/game_stepper.dart';
import '../document/document_session.dart';
import '../document/game_ordering.dart';

/// `‹ [n] of N ›` under the board: which game of the open file is showing,
/// with the number typeable to jump. Nothing when the document is not one
/// game of a file, so a merged repertoire chapter leaves the row out.
class GameCounter extends StatelessWidget {
  const GameCounter({super.key, required this.session, this.ordering});
  final GameOrdering? ordering;

  final DocumentSession session;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([session, ordering]),
      builder: (context, _) {
        final game = session.game;
        if (game == null) return const SizedBox.shrink();
        final order =
            ordering?.gameOrder ??
            List.generate(session.gameCount ?? 0, (i) => i);
        final at = order.indexOf(game);
        return GameStepper(
          at: at < 0 ? null : at,
          total: order.length,
          onShow: (index) => session.showGame(order[index]),
        );
      },
    );
  }
}

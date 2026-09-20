import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';

import '../engines/engine_line.dart';
import '../ui/theme.dart';

/// The bar beside the board: the share of the point White is expected to
/// score, filled from White's edge, as on Lichess. Even with no score.
class EvalBar extends StatelessWidget {
  const EvalBar({super.key, required this.score, required this.orientation});

  /// From White's side; null while the engine has nothing yet.
  final Score? score;

  final Side orientation;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: evalBarWidth,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: scheme.outline,
        borderRadius: BorderRadius.circular(2),
      ),
      child: Align(
        alignment: orientation == Side.white
            ? Alignment.bottomCenter
            : Alignment.topCenter,
        child: AnimatedFractionallySizedBox(
          duration: const Duration(milliseconds: 200),
          widthFactor: 1,
          heightFactor: score?.expected ?? 0.5,
          child: ColoredBox(color: scheme.onSurface),
        ),
      ),
    );
  }
}

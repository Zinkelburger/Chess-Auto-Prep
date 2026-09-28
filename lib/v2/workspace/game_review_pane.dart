import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../chess/pgn/game_review.dart';
import '../chess/pgn/move_label.dart';
import '../ui/theme.dart';
import 'game_review.dart';

/// Review and graph stay alongside the moves, with one obvious start action.
class GameReviewPane extends StatelessWidget {
  const GameReviewPane({super.key, required this.review});
  final GameReview review;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: review,
    builder: (context, _) {
      final values = review.values;
      final moves = review.session.tree?.children;
      final labels = <String>['Start'];
      var node = moves?.firstOrNull;
      while (node != null) {
        labels.add('${moveNumberLabel(node, startsLine: true)} ${node.san}');
        node = node.children.firstOrNull;
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(Space.m),
            child: Wrap(
              spacing: Space.m,
              runSpacing: Space.s,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: review.running
                      ? review.stop
                      : () => unawaited(review.start()),
                  icon: Icon(review.running ? Icons.stop : Icons.play_arrow),
                  label: Text(review.running ? 'Stop review' : 'Analyze game'),
                ),
                Text(
                  review.running
                      ? '${review.completed} / ${review.total} positions'
                      : 'Stockfish · depth ${review.depth}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (review.problem case final problem?)
            Padding(
              padding: const EdgeInsets.all(Space.m),
              child: Text(
                problem,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (!values.any((v) => v != null))
            Padding(
              padding: const EdgeInsets.all(Space.m),
              child: Text(
                'Analyze the whole game for evaluations, move annotations and suggested variations.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (values.any((v) => v != null)) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.m),
              child: Text(
                'Evaluation · White’s perspective',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            SizedBox(
              height: reviewGraphHeight,
              child: Padding(
                padding: const EdgeInsets.all(Space.m),
                child: LayoutBuilder(
                  builder: (context, size) => GestureDetector(
                    onTapDown: (event) => review.goTo(
                      (event.localPosition.dx /
                              size.maxWidth *
                              (values.length - 1))
                          .round()
                          .clamp(0, values.length - 1),
                    ),
                    child: CustomPaint(
                      painter: _Graph(values, Theme.of(context).colorScheme),
                      size: Size.infinite,
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: values.length,
                itemBuilder: (context, ply) {
                  final value = values[ply];
                  if (value == null) return const SizedBox.shrink();
                  final previous = ply > 0 ? values[ply - 1] : null;
                  final rootWhite =
                      review.session.tree?.rootFen.whiteToMove ?? true;
                  final whiteMoved = ply.isOdd == rootWhite;
                  final loss = previous == null
                      ? 0
                      : (previous.cp - value.cp) * (whiteMoved ? 1 : -1);
                  final label = switch (reviewGlyph(loss)) {
                    4 => 'Blunder',
                    2 => 'Mistake',
                    6 => 'Inaccuracy',
                    _ => '',
                  };
                  return ListTile(
                    dense: true,
                    title: Text(labels[ply]),
                    subtitle: label.isEmpty ? null : Text(label),
                    trailing: Text(value.eval),
                    onTap: () => review.goTo(ply),
                  );
                },
              ),
            ),
          ],
        ],
      );
    },
  );
}

class _Graph extends CustomPainter {
  _Graph(this.values, this.scheme);
  final List<ReviewValue?> values;
  final ColorScheme scheme;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawLine(
      Offset(0, size.height / 2),
      Offset(size.width, size.height / 2),
      Paint()..color = scheme.outlineVariant,
    );
    final path = Path();
    var continuing = false;
    for (var i = 0; i < values.length; i++) {
      final value = values[i];
      if (value == null) {
        continuing = false;
        continue;
      }
      final x = size.width * i / math.max(1, values.length - 1);
      final y = size.height * (0.5 - math.atan(value.cp / 200) / math.pi);
      if (continuing) {
        path.lineTo(x, y);
      } else {
        path.moveTo(x, y);
      }
      continuing = true;
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = scheme.primary
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_Graph old) =>
      old.values != values || old.scheme != scheme;
}

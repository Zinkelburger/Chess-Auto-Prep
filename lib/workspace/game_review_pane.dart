import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../chess/pgn/game_review.dart';
import '../chess/pgn/game_tree.dart';
import '../chess/pgn/move_label.dart';
import '../ui/theme.dart';
import 'game_review.dart';
import '../ui/move_notation.dart';

/// The game's evaluation as a graph, the old viewer's way: White's
/// advantage light above the middle, Black's dark below, each marked move a
/// coloured dot. The moves themselves stay in the Moves tab, where the
/// review writes its marks and better lines when the switch is on.
class GameReviewPane extends StatelessWidget {
  const GameReviewPane({super.key, required this.review});
  final GameReview review;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      review,
      review.session,
      review.session.cursorListenable,
    ]),
    builder: (context, _) {
      final theme = Theme.of(context);
      // Solitaire hides the rest of the game; the graph would give it away.
      if (review.session.shownTo != null) {
        return Padding(
          padding: const EdgeInsets.all(Space.m),
          child: Text(
            'Hidden until the whole game is shown',
            style: theme.textTheme.bodySmall,
          ),
        );
      }
      final values = review.values;
      final reviewed = values.any((v) => v != null);
      final moves = _mainline(review.session.tree);
      final rootWhite = review.session.tree?.rootFen.whiteToMove ?? true;
      final marks = [
        for (var ply = 0; ply < values.length; ply++)
          _markAt(values, ply, rootWhite),
      ];
      return ListView(
        padding: const EdgeInsets.all(Space.m),
        children: [
          Row(
            children: [
              FilledButton.icon(
                onPressed: review.running
                    ? review.stop
                    : () => unawaited(review.start()),
                icon: Icon(review.running ? Icons.stop : Icons.play_arrow),
                label: Text(
                  review.running
                      ? 'Stop'
                      : reviewed
                      ? 'Analyze again'
                      : 'Analyze game',
                ),
              ),
              const SizedBox(width: Space.m),
              Expanded(
                child: Text(
                  review.running
                      ? '${review.completed} / ${review.total} positions'
                      : 'Depth ${review.depth}',
                  style: theme.textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Tooltip(
                message: review.session.readOnly != null
                    ? 'This file is read-only'
                    : 'Write evaluations, ?/?? marks and better lines into the game',
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Annotate PGN', style: theme.textTheme.bodySmall),
                    Switch(
                      key: const ValueKey('review-annotate'),
                      value: review.annotate && review.session.readOnly == null,
                      onChanged: review.canAnnotate ? review.setAnnotate : null,
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (review.problem case final problem?)
            Padding(
              padding: const EdgeInsets.only(top: Space.s),
              child: Text(
                problem,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          const SizedBox(height: Space.m),
          if (!reviewed && !review.running)
            Text(
              'Analyze the game to graph its evaluation and mark its mistakes.',
              style: theme.textTheme.bodySmall,
            )
          else ...[
            EvalGraph(
              values: values,
              marks: marks,
              extent: math.max(review.positions, values.length),
              current: _plyOf(review.session.cursor),
              label: (ply) => ply == 0 || ply > moves.length
                  ? 'Start'
                  : displaySan(
                      context,
                      '${moveNumberLabel(moves[ply - 1], startsLine: true)} '
                      '${moves[ply - 1].san}',
                    ),
              onPly: review.goTo,
            ),
            const SizedBox(height: Space.m),
            for (final white in [true, false])
              _SideSummary(
                side: white ? 'White' : 'Black',
                values: values,
                marks: marks,
                rootWhite: rootWhite,
                white: white,
                current: _plyOf(review.session.cursor),
                onPly: review.goTo,
              ),
          ],
        ],
      );
    },
  );

  static List<MoveNode> _mainline(GameTree? tree) {
    final moves = <MoveNode>[];
    var move = tree?.children.firstOrNull;
    while (move != null) {
      moves.add(move);
      move = move.children.firstOrNull;
    }
    return moves;
  }

  /// The main-line ply the cursor is on or branched from.
  static int _plyOf(NodePath path) =>
      path.indexes.takeWhile((index) => index == 0).length;
}

/// Whether the move into [ply] was White's.
bool _whiteMoved(int ply, bool rootWhite) => ply.isOdd == rootWhite;

int _loss(List<ReviewValue?> values, int ply, bool rootWhite) {
  final before = ply > 0 ? values[ply - 1] : null;
  final after = values[ply];
  if (before == null || after == null) return 0;
  return (before.cp - after.cp) * (_whiteMoved(ply, rootWhite) ? 1 : -1);
}

ReviewMark? _markAt(List<ReviewValue?> values, int ply, bool rootWhite) =>
    reviewMark(_loss(values, ply, rootWhite));

Color markColor(ReviewMark mark) => switch (mark) {
  ReviewMark.inaccuracy => ReviewColors.inaccuracy,
  ReviewMark.mistake => ReviewColors.mistake,
  ReviewMark.blunder => ReviewColors.blunder,
};

String markGlyph(ReviewMark mark) => switch (mark) {
  ReviewMark.inaccuracy => '?!',
  ReviewMark.mistake => '?',
  ReviewMark.blunder => '??',
};

/// Lichess's winning-chances curve, −1…1, so a pawn matters near equality
/// and a rook more hardly moves a won game.
double _chances(int cp) =>
    2 / (1 + math.exp(-0.00368208 * cp.clamp(-1000, 1000))) - 1;

/// The graph: click or drag to go to a move, hover to read it.
class EvalGraph extends StatefulWidget {
  const EvalGraph({
    super.key,
    required this.values,
    required this.marks,
    required this.extent,
    required this.current,
    required this.label,
    required this.onPly,
  });

  final List<ReviewValue?> values;
  final List<ReviewMark?> marks;

  /// Positions the full game has, including those still being analysed.
  final int extent;
  final int current;
  final String Function(int ply) label;
  final ValueChanged<int> onPly;

  @override
  State<EvalGraph> createState() => _EvalGraphState();
}

class _EvalGraphState extends State<EvalGraph> {
  int? _hover;

  int _plyAt(double dx, double width) =>
      (dx / width * math.max(1, widget.extent - 1)).round().clamp(
        0,
        math.max(0, widget.values.length - 1),
      );

  void _hovered(int? ply) {
    if (!mounted || ply == _hover) return;
    setState(() => _hover = ply);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hover = _hover;
    final value = hover == null || hover >= widget.values.length
        ? null
        : widget.values[hover];
    final mark = hover == null || hover >= widget.marks.length
        ? null
        : widget.marks[hover];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: reviewGraphHeight,
          child: LayoutBuilder(
            builder: (context, size) {
              void go(Offset at) => widget.onPly(_plyAt(at.dx, size.maxWidth));
              return MouseRegion(
                cursor: SystemMouseCursors.click,
                onHover: (event) =>
                    _hovered(_plyAt(event.localPosition.dx, size.maxWidth)),
                onExit: (_) => _hovered(null),
                child: GestureDetector(
                  key: const ValueKey('review-graph'),
                  onTapDown: (event) => go(event.localPosition),
                  onHorizontalDragUpdate: (event) => go(event.localPosition),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(paneTabRadius),
                    child: CustomPaint(
                      painter: _GraphPainter(
                        values: widget.values,
                        marks: widget.marks,
                        extent: widget.extent,
                        current: widget.current,
                        hover: hover,
                        scheme: theme.colorScheme,
                      ),
                      size: Size.infinite,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        SizedBox(
          height: engineRowHeight,
          child: Align(
            alignment: Alignment.centerLeft,
            child: hover == null
                ? null
                : Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: widget.label(hover)),
                        if (mark != null)
                          TextSpan(
                            text: '${markGlyph(mark)}   ${mark.label}',
                            style: TextStyle(
                              color: markColor(mark),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        if (value != null) TextSpan(text: '   ${value.eval}'),
                      ],
                    ),
                    style: monoText.copyWith(
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}

class _GraphPainter extends CustomPainter {
  _GraphPainter({
    required this.values,
    required this.marks,
    required this.extent,
    required this.current,
    required this.hover,
    required this.scheme,
  });

  final List<ReviewValue?> values;
  final List<ReviewMark?> marks;
  final int extent;
  final int current;
  final int? hover;
  final ColorScheme scheme;

  @override
  void paint(Canvas canvas, Size size) {
    final middle = size.height / 2;
    double x(int ply) => size.width * ply / math.max(1, extent - 1);
    double y(ReviewValue value) =>
        middle - _chances(value.cp) * (middle - Space.xs);
    canvas.drawRect(Offset.zero & size, Paint()..color = ReviewColors.plot);

    final points = <Offset>[];
    for (var ply = 0; ply < values.length; ply++) {
      final value = values[ply];
      if (value != null) points.add(Offset(x(ply), y(value)));
    }
    if (points.isNotEmpty) {
      final area = Path()..moveTo(points.first.dx, middle);
      for (final point in points) {
        area.lineTo(point.dx, point.dy);
      }
      area
        ..lineTo(points.last.dx, middle)
        ..close();
      canvas
        ..save()
        ..clipRect(Rect.fromLTRB(0, 0, size.width, middle))
        ..drawPath(area, Paint()..color = ReviewColors.whiteArea)
        ..restore()
        ..save()
        ..clipRect(Rect.fromLTRB(0, middle, size.width, size.height))
        ..drawPath(area, Paint()..color = ReviewColors.blackArea)
        ..restore();
    }

    canvas.drawLine(
      Offset(0, middle),
      Offset(size.width, middle),
      Paint()
        ..color = scheme.onSurfaceVariant.withValues(alpha: 0.6)
        ..strokeWidth = 1,
    );

    if (current < values.length) {
      canvas.drawLine(
        Offset(x(current), 0),
        Offset(x(current), size.height),
        Paint()
          ..color = scheme.primary
          ..strokeWidth = 2,
      );
    }
    if (hover case final ply? when ply != current) {
      canvas.drawLine(
        Offset(x(ply), 0),
        Offset(x(ply), size.height),
        Paint()
          ..color = scheme.onSurface.withValues(alpha: 0.35)
          ..strokeWidth = 1,
      );
    }

    _curve(canvas, points);
    _marks(canvas, x, y);
  }

  void _curve(Canvas canvas, List<Offset> points) {
    if (points.length > 1) {
      final line = Path()..moveTo(points.first.dx, points.first.dy);
      for (final point in points.skip(1)) {
        line.lineTo(point.dx, point.dy);
      }
      canvas.drawPath(
        line,
        Paint()
          ..color = ReviewColors.line
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke
          ..strokeJoin = StrokeJoin.round,
      );
    }
  }

  void _marks(
    Canvas canvas,
    double Function(int) x,
    double Function(ReviewValue) y,
  ) {
    for (var ply = 0; ply < values.length && ply < marks.length; ply++) {
      final value = values[ply];
      final mark = marks[ply];
      if (value == null || mark == null) continue;
      final at = Offset(x(ply), y(value));
      final radius = mark == ReviewMark.blunder ? 4.5 : 3.5;
      canvas
        ..drawCircle(at, radius + 1.5, Paint()..color = ReviewColors.plot)
        ..drawCircle(at, radius, Paint()..color = markColor(mark));
    }
  }

  @override
  bool shouldRepaint(_GraphPainter old) =>
      old.values != values ||
      old.extent != extent ||
      old.current != current ||
      old.hover != hover ||
      old.scheme != scheme;
}

/// One side's marks and average loss. A mark count steps through that
/// side's moves of that kind.
class _SideSummary extends StatelessWidget {
  const _SideSummary({
    required this.side,
    required this.values,
    required this.marks,
    required this.rootWhite,
    required this.white,
    required this.current,
    required this.onPly,
  });

  final String side;
  final List<ReviewValue?> values;
  final List<ReviewMark?> marks;
  final bool rootWhite;
  final bool white;
  final int current;
  final ValueChanged<int> onPly;

  List<int> _plies(ReviewMark mark) => [
    for (var ply = 1; ply < marks.length; ply++)
      if (marks[ply] == mark && _whiteMoved(ply, rootWhite) == white) ply,
  ];

  int? get _averageLoss {
    var total = 0, count = 0;
    for (var ply = 1; ply < values.length; ply++) {
      if (_whiteMoved(ply, rootWhite) != white) continue;
      if (values[ply] == null || values[ply - 1] == null) continue;
      total += _loss(values, ply, rootWhite).clamp(0, 1000);
      count++;
    }
    return count == 0 ? null : (total / count).round();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loss = _averageLoss;
    return SizedBox(
      height: engineRowHeight,
      child: Row(
        children: [
          SizedBox(
            width: 56,
            child: Text(side, style: theme.textTheme.bodySmall),
          ),
          for (final mark in ReviewMark.values)
            _count(context, mark, _plies(mark)),
          const Spacer(),
          if (loss != null)
            Tooltip(
              message: 'Average centipawn loss',
              child: Text(
                'ACPL $loss',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _count(BuildContext context, ReviewMark mark, List<int> plies) {
    final theme = Theme.of(context);
    final next =
        plies.where((ply) => ply > current).firstOrNull ?? plies.firstOrNull;
    final color = plies.isEmpty
        ? theme.colorScheme.onSurfaceVariant
        : markColor(mark);
    return Tooltip(
      message:
          '${plies.length} ${mark.label.toLowerCase()}'
          '${plies.length == 1 ? '' : 's'}',
      child: InkWell(
        onTap: next == null ? null : () => onPly(next),
        borderRadius: BorderRadius.circular(3),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Space.s,
            vertical: Space.xs,
          ),
          child: Text(
            '${markGlyph(mark)} ${plies.length}',
            style: monoText.copyWith(
              color: color,
              fontWeight: plies.isEmpty ? null : FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

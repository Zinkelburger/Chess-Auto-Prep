/// Reusable widget that renders a list of SAN chess moves as clickable,
/// highlighted inline spans with move numbers.
///
/// Used by the analysis tab (best-line display), the inline engine bar
/// (PV continuation), and the interesting-move expected-move display.
library;

import 'package:flutter/material.dart';

class ClickableMoveLineWidget extends StatelessWidget {
  /// The SAN moves to render.
  final List<String> sanMoves;

  /// Ply (0-based half-move count from game start) of the first move in
  /// [sanMoves]. Determines move numbering and white/black assignment.
  final int startPly;

  /// Index (into [sanMoves]) of the currently highlighted move, if any.
  final int? activeMoveIndex;

  /// Called when the user clicks a move. Receives the 0-based index into
  /// [sanMoves].
  final ValueChanged<int>? onMoveTapped;

  /// Optional prefix text (e.g. "Best: ") rendered before the moves.
  final String? label;

  /// Index into [sanMoves] to begin rendering from (default 0).
  final int startIndex;

  /// Maximum number of moves to display (default 8).
  final int maxMoves;

  /// Font size for move text (default 11).
  final double fontSize;

  /// Whether to constrain to a single line with ellipsis overflow.
  final bool singleLine;

  const ClickableMoveLineWidget({
    super.key,
    required this.sanMoves,
    required this.startPly,
    this.activeMoveIndex,
    this.onMoveTapped,
    this.label,
    this.startIndex = 0,
    this.maxMoves = 8,
    this.fontSize = 11,
    this.singleLine = true,
  });

  @override
  Widget build(BuildContext context) {
    if (sanMoves.isEmpty) return const SizedBox.shrink();

    var moveNum = (startPly ~/ 2) + 1;
    var isWhite = startPly % 2 == 0;

    // Advance numbering past skipped moves
    for (int i = 0; i < startIndex; i++) {
      if (!isWhite) moveNum++;
      isWhite = !isWhite;
    }

    final spans = <InlineSpan>[];

    if (label != null) {
      spans.add(TextSpan(
        text: label,
        style: TextStyle(
          fontSize: fontSize,
          color: Colors.grey[600],
          fontFamily: 'monospace',
          fontWeight: FontWeight.bold,
        ),
      ));
    }

    final hasCallback = onMoveTapped != null;
    final end =
        (startIndex + maxMoves).clamp(startIndex, sanMoves.length);

    for (int i = startIndex; i < end; i++) {
      final isFirst = i == startIndex;

      if (isWhite) {
        spans.add(TextSpan(
          text: '$moveNum.',
          style: TextStyle(
              fontSize: fontSize,
              color: Colors.grey[600],
              fontFamily: 'monospace'),
        ));
      } else if (isFirst) {
        spans.add(TextSpan(
          text: '$moveNum...',
          style: TextStyle(
              fontSize: fontSize,
              color: Colors.grey[600],
              fontFamily: 'monospace'),
        ));
      }

      final isActive = activeMoveIndex == i;

      if (hasCallback) {
        final idx = i;
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => onMoveTapped!(idx),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                decoration: isActive
                    ? BoxDecoration(
                        color: Colors.teal[700],
                        borderRadius: BorderRadius.circular(2),
                      )
                    : null,
                child: Text(
                  sanMoves[i],
                  style: TextStyle(
                    fontSize: fontSize,
                    color: isActive ? Colors.white : Colors.teal[300],
                    fontFamily: 'monospace',
                    fontWeight:
                        isActive ? FontWeight.bold : FontWeight.normal,
                    decoration:
                        isActive ? null : TextDecoration.underline,
                    decorationColor: Colors.teal[300]!.withAlpha(80),
                    decorationStyle: TextDecorationStyle.dotted,
                  ),
                ),
              ),
            ),
          ),
        ));
        spans.add(TextSpan(
          text: ' ',
          style: TextStyle(fontSize: fontSize, fontFamily: 'monospace'),
        ));
      } else {
        spans.add(TextSpan(
          text: '${sanMoves[i]} ',
          style: TextStyle(
              fontSize: fontSize,
              color: Colors.grey[500],
              fontFamily: 'monospace'),
        ));
      }

      if (!isWhite) moveNum++;
      isWhite = !isWhite;
    }

    // Wrap in GestureDetector to absorb taps on move numbers / gaps so they
    // don't propagate to a parent InkWell and cause unintended navigation.
    return GestureDetector(
      onTap: () {},
      behavior: HitTestBehavior.opaque,
      child: RichText(
        text: TextSpan(children: spans),
        maxLines: singleLine ? 1 : null,
        overflow: singleLine ? TextOverflow.ellipsis : TextOverflow.clip,
      ),
    );
  }
}

import 'dart:math';

import 'package:flutter/material.dart';

import '../ui/theme.dart';
import 'action_layout.dart';

/// The board and reading card share the width recorded by the layout.
/// Pixel minima keep both usable as the window changes; the current mode
/// supplies their content without replacing the retained layout owner.
class BoardAndCard extends StatefulWidget {
  const BoardAndCard({required this.board, required this.card, this.layout});

  final ActionLayout? layout;

  final WidgetBuilder board;
  final WidgetBuilder card;

  @override
  State<BoardAndCard> createState() => BoardAndCardState();
}

class BoardAndCardState extends State<BoardAndCard> {
  double _share = 0.4;

  @override
  void initState() {
    super.initState();
    widget.layout?.addListener(_changed);
    _share = widget.layout?.boardFraction ?? 0.4;
  }

  @override
  void didUpdateWidget(BoardAndCard old) {
    super.didUpdateWidget(old);
    if (old.layout == widget.layout) return;
    old.layout?.removeListener(_changed);
    widget.layout?.addListener(_changed);
    _share = widget.layout?.boardFraction ?? 0.4;
  }

  void _changed() {
    if (mounted)
      setState(() => _share = widget.layout?.boardFraction ?? _share);
  }

  void _resize(double share) {
    setState(() => _share = share.clamp(0.2, 0.8));
    widget.layout?.resizeBoard(_share);
  }

  @override
  void dispose() {
    widget.layout?.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, room) {
      final width = max(0.0, room.maxWidth - paneDividerWidth);
      final minimum = min(
        boardPaneMinWidth,
        width * boardPaneMinWidth / (boardPaneMinWidth + readingPaneMinWidth),
      );
      final maximum = width - min(readingPaneMinWidth, width - minimum);
      final first = (width * _share).clamp(minimum, maximum);
      return Stack(
        children: [
          Row(
            children: [
              SizedBox(
                key: const ValueKey('board-area'),
                width: first,
                child: widget.board(context),
              ),
              Container(
                width: paneDividerWidth,
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
              Expanded(child: widget.card(context)),
            ],
          ),
          Positioned(
            left: first - paneDividerGrab,
            top: 0,
            bottom: 0,
            width: 2 * paneDividerGrab + paneDividerWidth,
            child: Semantics(
              label: 'Board width',
              onIncrease: () => _resize(_share + 0.05),
              onDecrease: () => _resize(_share - 0.05),
              child: MouseRegion(
                cursor: SystemMouseCursors.resizeColumn,
                child: GestureDetector(
                  key: const ValueKey('board-card-divider'),
                  behavior: HitTestBehavior.opaque,
                  onDoubleTap: () => _resize(0.4),
                  onHorizontalDragUpdate: width == 0
                      ? null
                      : (drag) => _resize(
                          (first + drag.delta.dx).clamp(minimum, maximum) /
                              width,
                        ),
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}

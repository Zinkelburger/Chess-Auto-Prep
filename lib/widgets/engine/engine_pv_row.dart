import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import '../clickable_move_line.dart';

/// A continuous, numbered PV with a fixed eval gutter and optional wrapping.
class EnginePvRow extends StatefulWidget {
  const EnginePvRow({
    super.key,
    required this.evaluation,
    required this.sanMoves,
    required this.startPly,
    this.evalColor,
    this.moveColor,
    this.trailing,
    this.onMoveTapped,
    this.onMoveHovered,
    this.onHoverExit,
  });

  final String evaluation;
  final List<String> sanMoves;
  final int startPly;
  final Color? evalColor;
  final Color? moveColor;
  final Widget? trailing;
  final ValueChanged<int>? onMoveTapped;
  final void Function(int index, Offset anchor)? onMoveHovered;
  final VoidCallback? onHoverExit;

  static double lineHeight(BuildContext context) =>
      MediaQuery.textScalerOf(context).scale(13) * 1.5 + 8.5;

  @override
  State<EnginePvRow> createState() => _EnginePvRowState();
}

class _EnginePvRowState extends State<EnginePvRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final line = ClickableMoveLineWidget(
      sanMoves: widget.sanMoves,
      startPly: widget.startPly,
      maxMoves: widget.sanMoves.length,
      maxLines: 1,
      singleLine: !_expanded,
      fontSize: 13,
      moveColor: widget.moveColor,
      movePadding: const EdgeInsets.symmetric(horizontal: 1),
      onMoveTapped: widget.onMoveTapped,
      onMoveHovered: widget.onMoveHovered,
      onHoverExit: widget.onHoverExit,
    );
    return Material(
      color: AppColors.engineSurface,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(
            bottom: BorderSide(color: AppColors.divider, width: 0.5),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 54,
              child: Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Text(
                  widget.evaluation,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.mono.copyWith(
                    fontWeight: FontWeight.w600,
                    color: widget.evalColor ?? AppColors.ink,
                  ),
                ),
              ),
            ),
            Expanded(
              // Streamed PV length must never move the following engine row.
              // Expansion is an explicit resize; subsequent updates scroll in
              // the same six-row viewport, including when the PV gets shorter.
              child: SizedBox(
                height: EnginePvRow.lineHeight(context) * (_expanded ? 6 : 1),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: _expanded
                      ? SingleChildScrollView(child: line)
                      : ClipRect(child: line),
                ),
              ),
            ),
            if (widget.trailing != null)
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: widget.trailing,
              ),
            SizedBox(
              width: 26,
              child: _expanded || widget.sanMoves.length > 1
                  ? IconButton(
                      style: const ButtonStyle(
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      tooltip: _expanded ? 'Collapse line' : 'Show full line',
                      icon: Icon(
                        _expanded ? Icons.expand_less : Icons.expand_more,
                        size: 16,
                      ),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 26,
                        height: 28,
                      ),
                      visualDensity: VisualDensity.compact,
                      onPressed: () {
                        if (!mounted) return;
                        widget.onHoverExit?.call();
                        setState(() => _expanded = !_expanded);
                      },
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

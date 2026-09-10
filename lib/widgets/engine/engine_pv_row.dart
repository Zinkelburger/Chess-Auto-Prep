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
    this.rows = 1,
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
  final int rows;
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
      maxLines: widget.rows,
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
              child: !_expanded && widget.rows == 1
                  ? SizedBox(
                      height: EnginePvRow.lineHeight(context),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: line,
                      ),
                    )
                  : ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: EnginePvRow.lineHeight(context),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: line,
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
              child: widget.sanMoves.length > 1
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

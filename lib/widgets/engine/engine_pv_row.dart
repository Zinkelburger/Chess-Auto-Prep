import 'package:flutter/material.dart';

import '../../design_system/theme/app_typography.dart';
import '../../design_system/theme/workspace_theme.dart';
import '../../l10n/generated/app_localizations.dart';
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

  static const double fontSize = 14;

  static double lineHeight(BuildContext context) =>
      MediaQuery.textScalerOf(context).scale(fontSize) * 1.5 + 8.5;

  @override
  State<EnginePvRow> createState() => _EnginePvRowState();
}

class _EnginePvRowState extends State<EnginePvRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final line = ClickableMoveLineWidget(
      sanMoves: widget.sanMoves,
      startPly: widget.startPly,
      maxMoves: widget.sanMoves.length,
      maxLines: 1,
      singleLine: !_expanded,
      fontSize: EnginePvRow.fontSize,
      moveColor: widget.moveColor,
      movePadding: const EdgeInsets.symmetric(horizontal: 1),
      onMoveTapped: widget.onMoveTapped,
      onMoveHovered: widget.onMoveHovered,
      onHoverExit: widget.onHoverExit,
    );
    return Material(
      color: WorkspaceTheme.of(context).panel,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: colors.outlineVariant, width: 0.5),
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
                  style: AppTypography.mono(context).copyWith(
                    fontSize: EnginePvRow.fontSize,
                    fontWeight: FontWeight.w400,
                    color: widget.evalColor ?? colors.onSurface,
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
                      tooltip: _expanded
                          ? l10n.engineAppearanceCollapseLine
                          : l10n.engineAppearanceShowFullLine,
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

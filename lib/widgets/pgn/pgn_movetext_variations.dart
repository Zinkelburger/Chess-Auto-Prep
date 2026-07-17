part of 'pgn_movetext_view.dart';

/// One full-width RichText row per variation root at [ply].
List<Widget> _buildVariationRowsAtPly(
  PgnMovetextView view,
  int ply, {
  bool ephemeralOnly = false,
}) {
  var roots = view.variationsByPly[ply];
  if (roots == null || roots.isEmpty) return const [];
  if (ephemeralOnly) {
    roots = roots.where((r) => r.isEphemeral).toList();
    if (roots.isEmpty) return const [];
  }

  final coords = _coordsAtPly(view, ply);
  final moveNum = coords.moveNumber;
  final isWhiteTurn = coords.isWhite;
  final rows = <Widget>[];

  for (final root in roots) {
    final bracketStyle = root.isEphemeral
        ? PgnTextStyles.ephemeral
        : PgnTextStyles.variation;
    final spans = <InlineSpan>[
      TextSpan(text: '( ', style: bracketStyle),
      ..._buildNodeSpans(view, root, moveNum, isWhiteTurn, true, ply),
      TextSpan(text: ')', style: bracketStyle),
    ];
    rows.add(
      RichText(
        // Root must stay family-free (variationRoot): move/bracket spans set
        // monospace themselves, while comment prose inherits the proportional
        // default. Rooting at bracketStyle would turn comments into code.
        text: TextSpan(style: PgnTextStyles.variationRoot, children: spans),
      ),
    );
  }

  return rows;
}

/// Recursively build spans for a node and its children.
List<InlineSpan> _buildNodeSpans(
  PgnMovetextView view,
  MoveNode node,
  int moveNumber,
  bool isWhiteTurn,
  bool isFirst,
  int branchPly,
) {
  final spans = <InlineSpan>[];
  final moveStyle = node.isEphemeral
      ? PgnTextStyles.ephemeral
      : PgnTextStyles.variation;

  // For null-move variation nodes, skip the move display entirely and just
  // show the comment inline.
  if (node.san == '--') {
    if (node.comment != null && node.comment!.isNotEmpty) {
      spans.addAll(_variationCommentSpans(view, node.comment!));
    }
    return spans;
  }

  if (isWhiteTurn) {
    spans.add(TextSpan(text: '$moveNumber. ', style: PgnTextStyles.moveNumber));
  } else if (isFirst) {
    spans.add(
      TextSpan(text: '$moveNumber... ', style: PgnTextStyles.moveNumber),
    );
  }

  final isCurrentNode =
      view.analysisPath.isNotEmpty && view.analysisPath.last.id == node.id;

  // Variation moves show their NAG glyphs too (e.g. "Nf3!?").
  final nodeNagSuffix = (node.nags != null && node.nags!.isNotEmpty)
      ? node.nags!.where((n) => n >= 1 && n <= 6).map(nagSymbol).join()
      : '';

  final activeStyle = isCurrentNode ? PgnTextStyles.currentMove : moveStyle;

  spans.add(
    WidgetSpan(
      alignment: PlaceholderAlignment.baseline,
      baseline: TextBaseline.alphabetic,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => view.onGoToAnalysisNode(node, branchPly),
        onSecondaryTapDown: view.onShowVariationContextMenu != null
            ? (details) => view.onShowVariationContextMenu!(
                node,
                branchPly,
                details.globalPosition,
              )
            : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
          decoration: isCurrentNode
              ? BoxDecoration(
                  color: node.isEphemeral
                      ? AppColors.pgnEphemeralBg
                      : AppColors.pgnMoveCurrentBg,
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(
                    color: node.isEphemeral
                        ? AppColors.pgnEphemeralMove
                        : AppColors.pgnMoveCurrent,
                    width: 1,
                  ),
                )
              // Reserve the border width so highlighting doesn't reflow.
              : BoxDecoration(
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(color: Colors.transparent, width: 1),
                ),
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: node.san,
                  style: activeStyle.copyWith(
                    decoration: isCurrentNode ? null : TextDecoration.underline,
                    decorationColor: AppColors.onSurfaceMuted.withValues(
                      alpha: 0.5,
                    ),
                    decorationStyle: TextDecorationStyle.dotted,
                  ),
                ),
                if (nodeNagSuffix.isNotEmpty)
                  TextSpan(
                    text: nodeNagSuffix,
                    style: activeStyle.copyWith(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  spans.add(const TextSpan(text: ' '));

  // Show comment after the move (for non-null-move variation nodes)
  if (node.comment != null && node.comment!.isNotEmpty) {
    spans.addAll(_variationCommentSpans(view, node.comment!));
  }

  final nextMoveNumber = isWhiteTurn ? moveNumber : moveNumber + 1;
  final nextIsWhite = !isWhiteTurn;

  if (node.children.isNotEmpty) {
    spans.addAll(
      _buildNodeSpans(
        view,
        node.children.first,
        nextMoveNumber,
        nextIsWhite,
        false,
        branchPly,
      ),
    );

    for (int i = 1; i < node.children.length; i++) {
      final variation = node.children[i];
      final subStyle = variation.isEphemeral
          ? PgnTextStyles.ephemeral
          : PgnTextStyles.variation;

      spans.add(TextSpan(text: '( ', style: subStyle));
      spans.addAll(
        _buildNodeSpans(
          view,
          variation,
          nextMoveNumber,
          nextIsWhite,
          true,
          branchPly,
        ),
      );
      spans.add(TextSpan(text: ') ', style: subStyle));
    }
  }

  return spans;
}

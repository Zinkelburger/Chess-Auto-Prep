part of 'pgn_movetext_view.dart';

/// Nesting depth of a sideline branching directly off the mainline. The
/// mainline itself is depth 0.
const _kRootVariationDepth = 1;

/// Deepest sideline level rendered unconditionally. Alternatives that would
/// land deeper are folded behind a "▸ N more lines" stub the reader can open.
/// Machine-generated repertoire trees routinely nest far past anything a human
/// wants to read in one pass; without a fold they bury the mainline.
const _kAlwaysVisibleDepth = 2;

/// A single rendered row of sideline movetext, or the disclosure stub standing
/// in for a folded group.
class _VarRow {
  final int depth;

  /// Spans of the row. Empty for a stub row.
  final List<InlineSpan> spans;

  /// Non-null when this row is a fold disclosure for the branch under this
  /// node id.
  final int? branchId;

  /// Number of alternatives hidden (or revealed) by the stub.
  final int hiddenCount;

  /// Whether the folded group is currently open.
  final bool open;

  const _VarRow(this.depth, this.spans)
    : branchId = null,
      hiddenCount = 0,
      open = false;

  const _VarRow.stub(
    this.depth,
    this.branchId,
    this.hiddenCount, {
    required this.open,
  }) : spans = const [];

  bool get isStub => branchId != null;
}

/// Build the widget rows for every sideline branching at [ply].
///
/// Each row is indented one step per nesting level and carries a hairline in
/// its left gutter, so depth survives both wrapping and a narrow pane. There
/// are deliberately no `( )` brackets: indentation, the gutter rule, and the
/// ink/weight step already say "sideline", and stacked parentheses are exactly
/// what makes deep trees unreadable.
List<Widget> _buildVariationRowsAtPly(
  PgnMovetextView view,
  int ply, {
  bool ephemeralOnly = false,
  required Set<int> expandedBranches,
  required ValueChanged<int> onToggleBranch,
}) {
  var roots = view.variationsByPly[ply];
  if (roots == null || roots.isEmpty) return const [];
  if (ephemeralOnly) {
    roots = roots.where((r) => r.isEphemeral).toList();
    if (roots.isEmpty) return const [];
  }

  final coords = _coordsAtPly(view, ply);
  final rows = <_VarRow>[];

  for (final root in roots) {
    final row = <InlineSpan>[];
    _walkVariation(
      view,
      root,
      moveNumber: coords.moveNumber,
      isWhiteTurn: coords.isWhite,
      isFirstOfRow: true,
      depth: _kRootVariationDepth,
      branchPly: ply,
      row: row,
      out: rows,
      expandedBranches: expandedBranches,
    );
    if (row.isNotEmpty) rows.add(_VarRow(_kRootVariationDepth, row));
  }

  return [for (final row in rows) _variationRowWidget(row, onToggleBranch)];
}

/// Walk a sideline, appending spans to [row] and completed rows to [out].
///
/// A node's first child continues the *same* row; every further child is an
/// alternative, so the row is closed at the branch point, the alternatives are
/// emitted as their own indented rows, and the continuation resumes on a fresh
/// row at the same depth (re-stating `N...` for Black). That break-and-resume
/// shape is what makes a sub-variation visible instead of buried mid-line.
void _walkVariation(
  PgnMovetextView view,
  MoveNode node, {
  required int moveNumber,
  required bool isWhiteTurn,
  required bool isFirstOfRow,
  required int depth,
  required int branchPly,
  required List<InlineSpan> row,
  required List<_VarRow> out,
  required Set<int> expandedBranches,
}) {
  final isNullMove = isNullMoveSan(node.san);

  // Null-move nodes pass the turn: show any comment, hide the SAN, then
  // keep walking so `1. d4 Z0 2. Nf3` does not stop at the pass.
  if (isNullMove) {
    if (node.comment != null && node.comment!.isNotEmpty) {
      row.addAll(_variationCommentSpans(view, node.comment!, depth));
    }
  } else {
    if (isWhiteTurn) {
      row.add(
        TextSpan(
          text: '$moveNumber. ',
          style: PgnTextStyles.moveNumberAt(depth),
        ),
      );
    } else if (isFirstOfRow) {
      row.add(
        TextSpan(
          text: '$moveNumber... ',
          style: PgnTextStyles.moveNumberAt(depth),
        ),
      );
    }

    row.add(_variationMoveSpan(view, node, depth, branchPly));
    row.add(const TextSpan(text: ' '));

    if (node.comment != null && node.comment!.isNotEmpty) {
      row.addAll(_variationCommentSpans(view, node.comment!, depth));
    }
  }

  if (node.children.isEmpty) return;

  final nextMoveNumber = isWhiteTurn ? moveNumber : moveNumber + 1;
  final nextIsWhite = !isWhiteTurn;

  if (node.children.length == 1) {
    _walkVariation(
      view,
      node.children.first,
      moveNumber: nextMoveNumber,
      isWhiteTurn: nextIsWhite,
      isFirstOfRow: isNullMove ? isFirstOfRow : false,
      depth: depth,
      branchPly: branchPly,
      row: row,
      out: out,
      expandedBranches: expandedBranches,
    );
    return;
  }

  // Branch point: close the row here so the alternatives sit directly under
  // the move they replace.
  out.add(_VarRow(depth, List.of(row)));
  row.clear();

  final alternatives = node.children.skip(1).toList();
  final altDepth = depth + 1;
  final folded = altDepth > _kAlwaysVisibleDepth;
  final open = !folded || expandedBranches.contains(node.id);

  if (folded) {
    out.add(_VarRow.stub(altDepth, node.id, alternatives.length, open: open));
  }

  if (open) {
    for (final alternative in alternatives) {
      final altRow = <InlineSpan>[];
      _walkVariation(
        view,
        alternative,
        moveNumber: nextMoveNumber,
        isWhiteTurn: nextIsWhite,
        isFirstOfRow: true,
        depth: altDepth,
        branchPly: branchPly,
        row: altRow,
        out: out,
        expandedBranches: expandedBranches,
      );
      if (altRow.isNotEmpty) out.add(_VarRow(altDepth, altRow));
    }
  }

  // Resume the continuation on a fresh row at this depth.
  _walkVariation(
    view,
    node.children.first,
    moveNumber: nextMoveNumber,
    isWhiteTurn: nextIsWhite,
    isFirstOfRow: true,
    depth: depth,
    branchPly: branchPly,
    row: row,
    out: out,
    expandedBranches: expandedBranches,
  );
}

/// A tappable SAN chip inside a sideline row.
InlineSpan _variationMoveSpan(
  PgnMovetextView view,
  MoveNode node,
  int depth,
  int branchPly,
) {
  final isCurrentNode =
      view.analysisPath.isNotEmpty && view.analysisPath.last.id == node.id;

  // Every NAG, same as the mainline — a sideline's `⩲` is the reason the
  // sideline is there.
  final nagSuffix = allNagSuffix(node.nags);

  final base = PgnTextStyles.moveAt(depth, ephemeral: node.isEphemeral);
  final sanStyle = isCurrentNode
      ? base.copyWith(color: AppColors.pgnMoveCurrentFg)
      : base;
  final currentDecoration = BoxDecoration(
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
  );

  return WidgetSpan(
    alignment: PlaceholderAlignment.baseline,
    baseline: TextBaseline.alphabetic,
    child: MoveChip(
      san: node.san,
      nagSuffix: nagSuffix,
      sanStyle: sanStyle,
      nagStyle: sanStyle.copyWith(
        fontSize: PgnTextStyles.sizeAt(depth) - 1,
        fontWeight: FontWeight.bold,
      ),
      decoration: isCurrentNode ? currentDecoration : _kReservedBorder,
      hoverDecoration: isCurrentNode ? currentDecoration : _kHoverDecoration,
      behavior: HitTestBehavior.opaque,
      onTap: () => view.onGoToAnalysisNode(node, branchPly),
      onSecondaryTapDown: view.onShowVariationContextMenu != null
          ? (details) => view.onShowVariationContextMenu!(
              node,
              branchPly,
              details.globalPosition,
            )
          : null,
    ),
  );
}

/// Indent a row by its depth and draw the gutter hairline that carries the
/// depth signal through wrapped lines.
Widget _variationRowWidget(_VarRow row, ValueChanged<int> onToggleBranch) {
  final Widget content = row.isStub
      ? _foldStub(row, onToggleBranch)
      : RichText(
          text: TextSpan(
            style: PgnTextStyles.rowRootAt(row.depth),
            children: row.spans,
          ),
        );

  return Padding(
    padding: EdgeInsets.only(
      left: (row.depth - _kRootVariationDepth) * PgnTextStyles.depthIndent,
      top: 1,
      bottom: 1,
    ),
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.only(left: 8),
      decoration: const BoxDecoration(
        border: Border(
          left: BorderSide(color: AppColors.pgnVariationRule, width: 1),
        ),
      ),
      child: content,
    ),
  );
}

/// The "▸ 3 more lines" disclosure standing in for a folded group.
Widget _foldStub(_VarRow row, ValueChanged<int> onToggleBranch) {
  final n = row.hiddenCount;
  final label = row.open
      ? '▾ ${n == 1 ? '1 line' : '$n lines'}'
      : '▸ ${n == 1 ? '1 more line' : '$n more lines'}';
  return MouseRegion(
    cursor: SystemMouseCursors.click,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onToggleBranch(row.branchId!),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Text(label, style: PgnTextStyles.collapsedStub),
      ),
    ),
  );
}
